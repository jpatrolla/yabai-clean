#include <Carbon/Carbon.h>
#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include "space_indicator.h"
#include "display.h"
#include "display_manager.h"
#include "space_manager.h"
#include "sa.h"
#include "misc/extern.h"
#include "misc/helpers.h"

extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern int g_connection;
extern double g_cv_host_clock_frequency;

#define ANIMATION_DURATION 0.12  // 120ms for snappy feel

// Forward declaration
static CVReturn space_indicator_display_link_callback(CVDisplayLinkRef link, const CVTimeStamp *now, 
                                                       const CVTimeStamp *output_time, CVOptionFlags flags_in, 
                                                       CVOptionFlags *flags_out, void *context);

static void space_indicator_redraw(struct space_indicator *indicator)
{
    if (!indicator->is_active) return;
    
    // Create drawing context and set color from config
    CGContextRef context = SLWindowContextCreate(g_connection, indicator->id, 0);
    if (context) {
        CGRect local_frame = {{0, 0}, {indicator->frame.size.width, indicator->frame.size.height}};
        
        // Extract RGBA from the color config (format: 0xAARRGGBB)
        float alpha = ((indicator->config.indicator_color >> 24) & 0xFF) / 255.0f;
        float red   = ((indicator->config.indicator_color >> 16) & 0xFF) / 255.0f;
        float green = ((indicator->config.indicator_color >> 8) & 0xFF) / 255.0f;
        float blue  = (indicator->config.indicator_color & 0xFF) / 255.0f;
        
        CGContextSetRGBFillColor(context, red, green, blue, alpha);
        SLSDisableUpdate(g_connection);
        CGContextFillRect(context, local_frame);
        CGContextFlush(context);
        SLSReenableUpdate(g_connection);
        CFRelease(context);
    }
    
    indicator->needs_redraw = false;
}

void space_indicator_create(struct space_indicator *indicator)
{
    if (indicator->is_active || !indicator->config.enabled) return;
    
    // Get main display dimensions
    uint32_t did = display_manager_main_display_id();
    CGRect display_frame = CGDisplayBounds(did);
    
    // Calculate indicator dimensions
    int space_count = display_space_count(did);
    if (space_count <= 0) return;
    
    float indicator_width = display_frame.size.width / space_count;
    int current_space_index = space_manager_mission_control_index(g_space_manager.current_space_id);
    if (current_space_index < 1) current_space_index = 1;
    
    float x_position = (current_space_index - 1) * indicator_width;
    
    // Calculate y position based on config
    float y_position = indicator->config.position == 0 ? 
                       0 : // top
                       display_frame.size.height - indicator->config.indicator_height; // bottom
    
    // Create window frame
    indicator->frame = (CGRect) {
        .origin.x = x_position,
        .origin.y = y_position,
        .size.width = indicator_width,
        .size.height = indicator->config.indicator_height
    };
    
    // Initialize animation fields
    indicator->start_frame = indicator->frame;
    indicator->target_frame = indicator->frame;
    indicator->is_animating = false;
    indicator->animation_start_time = 0;
    indicator->needs_redraw = true;
    indicator->display_link = NULL;
    indicator->cached_region = NULL;
    
    // Create the indicator window
    CFTypeRef frame_region;
    CGSNewRegionWithRect(&indicator->frame, &frame_region);
    
    uint64_t tags = (1ULL << 1) | (1ULL << 9);  // Sticky and floating
    CFTypeRef empty_region = CGRegionCreateEmptyRegion();
    
    SLSNewWindowWithOpaqueShapeAndContext(g_connection, 2, frame_region, empty_region, 13, &tags, 0, 0, 64, &indicator->id, NULL);
    CFRelease(empty_region);
    CFRelease(frame_region);
    
    // Make the window sticky (appear on all spaces)
    scripting_addition_set_sticky(indicator->id, true);
    
    SLSSetWindowResolution(g_connection, indicator->id, 1.0f);
    SLSSetWindowOpacity(g_connection, indicator->id, 0);
    SLSSetWindowLevel(g_connection, indicator->id, CGWindowLevelForKey(kCGFloatingWindowLevelKey));
    
    // Order the window
    SLSOrderWindow(g_connection, indicator->id, 1, 0);
    
    indicator->is_active = true;
    
    // Draw the indicator with the correct color
    space_indicator_redraw(indicator);
}

void space_indicator_destroy(struct space_indicator *indicator)
{
    if (!indicator->is_active) return;
    
    // Stop and release display link if active
    if (indicator->display_link) {
        CVDisplayLinkStop(indicator->display_link);
        CVDisplayLinkRelease(indicator->display_link);
        indicator->display_link = NULL;
    }
    
    // Release cached region if exists
    if (indicator->cached_region) {
        CFRelease(indicator->cached_region);
        indicator->cached_region = NULL;
    }
    
    SLSReleaseWindow(g_connection, indicator->id);
    indicator->id = 0;
    indicator->is_active = false;
    indicator->is_animating = false;
}

static void space_indicator_start_animation(struct space_indicator *indicator)
{
    if (!indicator->is_active) return;
    
    // Create display link if it doesn't exist
    if (!indicator->display_link) {
        CVDisplayLinkCreateWithActiveCGDisplays(&indicator->display_link);
        CVDisplayLinkSetOutputCallback(indicator->display_link, space_indicator_display_link_callback, indicator);
    }
    
    indicator->animation_start_time = mach_absolute_time();
    indicator->is_animating = true;
    
    // Start the display link
    CVDisplayLinkStart(indicator->display_link);
}

static void space_indicator_stop_animation(struct space_indicator *indicator)
{
    if (indicator->display_link) {
        CVDisplayLinkStop(indicator->display_link);
    }
    indicator->is_animating = false;
}

// CVDisplayLink callback for VSync-synchronized animation
static CVReturn space_indicator_display_link_callback(CVDisplayLinkRef link, const CVTimeStamp *now, 
                                                       const CVTimeStamp *output_time, CVOptionFlags flags_in, 
                                                       CVOptionFlags *flags_out, void *context)
{
    struct space_indicator *indicator = (struct space_indicator *)context;
    
    if (!indicator->is_animating) return kCVReturnSuccess;
    
    // Calculate animation progress
    uint64_t current_time = mach_absolute_time();
    double elapsed_ns = (double)(current_time - indicator->animation_start_time) / g_cv_host_clock_frequency;
    float progress = (float)(elapsed_ns / ANIMATION_DURATION);
    
    if (progress >= 1.0f) {
        // Animation complete
        progress = 1.0f;
        indicator->frame = indicator->target_frame;
        
        // Use SLS transaction to batch final position update
        CFTypeRef transaction = SLSTransactionCreate(g_connection);
        SLSMoveWindow(g_connection, indicator->id, &indicator->frame.origin);
        
        // Update cached region for final frame if needed
        if (indicator->cached_region) {
            CFRelease(indicator->cached_region);
        }
        CGSNewRegionWithRect(&indicator->frame, &indicator->cached_region);
        SLSSetWindowShape(g_connection, indicator->id, 0, 0, indicator->cached_region);
        SLSTransactionCommit(transaction, 0);
        
        space_indicator_stop_animation(indicator);
        return kCVReturnSuccess;
    }
    
    // Apply easing function (use ease_out_cubic from helpers.h)
    float eased_progress = ease_out_cubic(progress);
    
    // Interpolate position and width
    indicator->frame.origin.x = indicator->start_frame.origin.x + 
                                (indicator->target_frame.origin.x - indicator->start_frame.origin.x) * eased_progress;
    indicator->frame.size.width = indicator->start_frame.size.width + 
                                  (indicator->target_frame.size.width - indicator->start_frame.size.width) * eased_progress;
    
    // Use SLS transaction to batch move and shape updates
    CFTypeRef transaction = SLSTransactionCreate(g_connection);
    SLSMoveWindow(g_connection, indicator->id, &indicator->frame.origin);
    
    // Update cached region
    if (indicator->cached_region) {
        CFRelease(indicator->cached_region);
    }
    CGSNewRegionWithRect(&indicator->frame, &indicator->cached_region);
    SLSSetWindowShape(g_connection, indicator->id, 0, 0, indicator->cached_region);
    SLSTransactionCommit(transaction, 0);
    
    return kCVReturnSuccess;
}

void space_indicator_update(struct space_indicator *indicator, uint64_t sid)
{
    if (!indicator->is_active || !indicator->config.enabled) return;
    
    // Cancel any ongoing animation
    if (indicator->is_animating) {
        space_indicator_stop_animation(indicator);
    }
    
    // Get display dimensions
    uint32_t did = display_manager_main_display_id();
    CGRect display_frame = CGDisplayBounds(did);
    
    // Calculate new position
    int space_count = display_space_count(did);
    if (space_count <= 0) return;
    
    float indicator_width = display_frame.size.width / space_count;
    int space_index = space_manager_mission_control_index(sid);
    if (space_index < 1) space_index = 1;
    
    float x_position = (space_index - 1) * indicator_width;
    
    // Calculate y position based on config
    float y_position = indicator->config.position == 0 ? 
                       0 : // top
                       display_frame.size.height - indicator->config.indicator_height; // bottom

    // Set target frame for animation
    CGRect new_target = {
        .origin.x = x_position,
        .origin.y = y_position,
        .size.width = indicator_width,
        .size.height = indicator->config.indicator_height
    };
    
    // Check if position actually changed
    if (fabs(indicator->frame.origin.x - new_target.origin.x) < 1.0f &&
        fabs(indicator->frame.size.width - new_target.size.width) < 1.0f) {
        return; // No significant change, skip animation
    }
    
    // Get current position from the window
    CGRect current_bounds;
    SLSGetWindowBounds(g_connection, indicator->id, &current_bounds);
    indicator->start_frame = current_bounds;
    indicator->frame = current_bounds;
    indicator->target_frame = new_target;
    
    // Start animation
    space_indicator_start_animation(indicator);
}

void space_indicator_update_optimistic(struct space_indicator *indicator, uint64_t sid)
{
    if (!indicator->is_active || !indicator->config.enabled) return;
    
    // Cancel any ongoing animation
    if (indicator->is_animating) {
        space_indicator_stop_animation(indicator);
    }
    
    // Get display dimensions
    uint32_t did = display_manager_main_display_id();
    CGRect display_frame = CGDisplayBounds(did);
    
    // Calculate new position
    int space_count = display_space_count(did);
    if (space_count <= 0) return;
    
    float indicator_width = display_frame.size.width / space_count;
    int space_index = space_manager_mission_control_index(sid);
    if (space_index < 1) space_index = 1;
    
    float x_position = (space_index - 1) * indicator_width;
    
    // Calculate y position based on config
    float y_position = indicator->config.position == 0 ? 
                       0 : // top
                       display_frame.size.height - indicator->config.indicator_height; // bottom

    // Set target frame for animation
    CGRect new_target = {
        .origin.x = x_position,
        .origin.y = y_position,
        .size.width = indicator_width,
        .size.height = indicator->config.indicator_height
    };
    
    // Check if position actually changed
    if (fabs(indicator->frame.origin.x - new_target.origin.x) < 1.0f &&
        fabs(indicator->frame.size.width - new_target.size.width) < 1.0f) {
        return; // No significant change, skip animation
    }
    
    // Always start from current position for optimistic animation
    CGRect current_bounds;
    SLSGetWindowBounds(g_connection, indicator->id, &current_bounds);
    indicator->start_frame = current_bounds;
    indicator->frame = current_bounds;
    indicator->target_frame = new_target;
    
    // Start animation immediately (optimistic)
    space_indicator_start_animation(indicator);
}

void space_indicator_refresh(struct space_indicator *indicator)
{
    if (!indicator->is_active) return;
    
    // Update position for current space
    space_indicator_update(indicator, g_space_manager.current_space_id);
    
    // Force a redraw to apply any config changes (color, etc.)
    indicator->needs_redraw = true;
    space_indicator_redraw(indicator);
}
