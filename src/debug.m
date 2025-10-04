#include "debug.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <libproc.h>
#include <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
#include "misc/extern.h"

// External globals and functions needed for debug functions
extern int g_connection;
extern uint64_t space_manager_active_space(void);
extern CFArrayRef cfarray_of_cfnumbers(void *values, size_t size, int count, CFNumberType type);
extern CGRect SLSWindowGetTileRect(int cid, uint32_t wid);

// Stage Manager / Tile APIs
extern bool CGSSpaceCanCreateTile(int cid, uint64_t sid);
extern CGError CGSSpaceGetSizeForProposedTile(int cid, uint64_t sid, CGSize *outSize);
extern CGFloat CGSSpaceGetInterTileSpacing(int cid, uint64_t sid);
extern CFArrayRef CGSSpaceCopyTileSpaces(int cid, uint64_t sid);

// Workspace APIs
extern int SLSGetWorkspace(int cid);
extern int SLSGetWindowWorkspace(int cid, uint32_t wid);
extern int SLSGetWorkspaceWindowCountWithOptionsAndTags(int cid, int workspace, int options, uint64_t *set_tags, uint64_t *clear_tags);
extern int SLSGetWorkspaceWindowListWithOptionsAndTags(int cid, int workspace, int options, int count, uint32_t *list, uint64_t *set_tags, uint64_t *clear_tags);
extern uint64_t SLSGetWorkspaceWindowGroup(int cid, uint32_t wid,int workspace);

// Packages APIs
extern CGError SLSPackagesGetWindowConstraints(int cid, uint32_t wid, CGRect *outConstraints);

void debug_call_api(FILE *rsp, const char *test_func, const char *args)
{
    if (strcmp(test_func, "space_iterator") == 0) {
        // Check if we should only print IDs
        bool ids_only = (args && strcmp(args, "ids_only") == 0);
        
        // Get space ID from args or use active space
        uint64_t sid = 0;
        
        if (args && *args && !ids_only) {
            sid = strtoull(args, NULL, 10);
        }
        
        if (sid == 0) {
            sid = space_manager_active_space();
        }
        
        if (!ids_only) {
            fprintf(rsp, "=== Space Iterator Data ===\n\n");
            fprintf(rsp, "Space ID: %llu\n\n", sid);
        }
        
        // Get windows for this space to create a query
        uint64_t set_tags = 0;
        uint64_t clear_tags = 0;
        CFArrayRef space_ref = cfarray_of_cfnumbers(&sid, sizeof(uint64_t), 1, kCFNumberSInt64Type);
        CFArrayRef window_list_ref = SLSCopyWindowsWithOptionsAndTags(g_connection, 0, space_ref, 0x7, &set_tags, &clear_tags);
        
        if (!window_list_ref) {
            fprintf(rsp, "ERROR: SLSCopyWindowsWithOptionsAndTags returned NULL\n");
            CFRelease(space_ref);
            return;
        }
        
        int window_count = CFArrayGetCount(window_list_ref);
        if (!ids_only) {
            fprintf(rsp, "Found %d windows on this space\n", window_count);
        }
        
        if (window_count == 0) {
            if (!ids_only) {
                fprintf(rsp, "⚠️  No windows on this space, can't query space iterator\n");
            }
            CFRelease(window_list_ref);
            CFRelease(space_ref);
            return;
        }
        
        // Create window query
        CFTypeRef query = SLSWindowQueryWindows(g_connection, window_list_ref, window_count);
        if (!query) {
            fprintf(rsp, "ERROR: SLSWindowQueryWindows failed\n");
            CFRelease(window_list_ref);
            CFRelease(space_ref);
            return;
        }
        
        // Get space iterator
        CFTypeRef iterator = SLSWindowQueryResultCopySpaces(query);
        if (!iterator) {
            fprintf(rsp, "ERROR: SLSWindowQueryResultCopySpaces returned NULL\n");
            CFRelease(query);
            CFRelease(window_list_ref);
            CFRelease(space_ref);
            return;
        }
        
        // Check if it's an iterator or a CFArray
        CFTypeID type_id = CFGetTypeID(iterator);
        bool is_array = (type_id == CFArrayGetTypeID());
        
        if (!ids_only) {
            if (is_array) {
                CFIndex count = CFArrayGetCount((CFArrayRef)iterator);
                fprintf(rsp, "Result is CFArray with %ld space(s)\n\n", count);
                
                // Process array
                for (CFIndex i = 0; i < count; i++) {
                    CFTypeRef item = CFArrayGetValueAtIndex((CFArrayRef)iterator, i);
                    if (CFGetTypeID(item) == CFNumberGetTypeID()) {
                        uint64_t space_id = 0;
                        CFNumberGetValue((CFNumberRef)item, kCFNumberSInt64Type, &space_id);
                        
                        fprintf(rsp, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
                        fprintf(rsp, "SPACE #%ld\n", i);
                        fprintf(rsp, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n");
                        
                        fprintf(rsp, "  SpaceID:  %llu", space_id);
                        if (space_id == sid) fprintf(rsp, " ✅ (current)");
                        fprintf(rsp, "\n");
                        
                        // Get type for this space
                        int space_type = SLSSpaceGetType(g_connection, space_id);
                        fprintf(rsp, "  Type:     %d", space_type);
                        if (space_type == 0) fprintf(rsp, " (User/Desktop)");
                        else if (space_type == 1) fprintf(rsp, " (Fullscreen)");
                        else if (space_type == 2) fprintf(rsp, " (System)");
                        else if (space_type == 4) fprintf(rsp, " 🔥 (STAGE MANAGER?)");
                        fprintf(rsp, "\n\n");
                    }
                }
            } else {
                // It's an iterator
                int iter_count = SLSSpaceIteratorGetCount(iterator);
                fprintf(rsp, "Result is Space Iterator with %d space(s)\n\n", iter_count);
                
                int space_index = 0;
                while (SLSSpaceIteratorAdvance(iterator)) {
                    fprintf(rsp, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
                    fprintf(rsp, "SPACE #%d\n", space_index++);
                    fprintf(rsp, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n");
                    
                    uint64_t iter_sid = SLSSpaceIteratorGetSpaceID(iterator);
                    fprintf(rsp, "  SpaceID:        %llu", iter_sid);
                    if (iter_sid == sid) fprintf(rsp, " ✅ (current)");
                    fprintf(rsp, "\n");
                    
                    uint64_t attributes = SLSSpaceIteratorGetAttributes(iterator);
                    fprintf(rsp, "  Attributes:     0x%016llx\n", attributes);
                    
                    // Decode attribute bits
                    fprintf(rsp, "    Bit flags:    ");
                    if (attributes & 0x1) fprintf(rsp, "0x1 ");
                    if (attributes & 0x2) fprintf(rsp, "0x2 ");
                    if (attributes & 0x4) fprintf(rsp, "0x4 ");
                    if (attributes & 0x8) fprintf(rsp, "0x8 ");
                    if (attributes & 0x10) fprintf(rsp, "0x10 ");
                    if (attributes & 0x20) fprintf(rsp, "0x20 ");
                    if (attributes & 0x40) fprintf(rsp, "0x40 ");
                    if (attributes & 0x80) fprintf(rsp, "0x80 ");
                    fprintf(rsp, "\n");
                    
                    if (attributes & 0x1) {
                        fprintf(rsp, "    🔥 BIT 0x1 SET - Likely kCGSSpaceTiled!\n");
                    }
                    if (attributes & 0x4) {
                        fprintf(rsp, "    🔥 BIT 0x4 SET - Possible Stage Manager flag!\n");
                    }
                    
                    int space_type = SLSSpaceIteratorGetType(iterator);
                    fprintf(rsp, "  Type:           %d", space_type);
                    if (space_type == 0) fprintf(rsp, " (User/Desktop)");
                    else if (space_type == 1) fprintf(rsp, " (Fullscreen)");
                    else if (space_type == 2) fprintf(rsp, " (System)");
                    else if (space_type == 4) fprintf(rsp, " 🔥 (STAGE MANAGER?)");
                    fprintf(rsp, "\n");
                    
                    uint64_t parent_sid = SLSSpaceIteratorGetParentSpaceID(iterator);
                    fprintf(rsp, "  ParentSpaceID:  %llu", parent_sid);
                    if (parent_sid != 0) fprintf(rsp, " 🔥 HAS PARENT!");
                    fprintf(rsp, "\n\n");
                }
            }
            
            fprintf(rsp, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
        } else {
            // ids_only mode
            if (is_array) {
                CFIndex count = CFArrayGetCount((CFArrayRef)iterator);
                for (CFIndex i = 0; i < count; i++) {
                    CFTypeRef item = CFArrayGetValueAtIndex((CFArrayRef)iterator, i);
                    if (CFGetTypeID(item) == CFNumberGetTypeID()) {
                        uint64_t space_id = 0;
                        CFNumberGetValue((CFNumberRef)item, kCFNumberSInt64Type, &space_id);
                        fprintf(rsp, "%llu\n", space_id);
                    }
                }
            } else {
                while (SLSSpaceIteratorAdvance(iterator)) {
                    fprintf(rsp, "%llu\n", SLSSpaceIteratorGetSpaceID(iterator));
                }
            }
        }
        
        CFRelease(iterator);
        CFRelease(query);
        CFRelease(window_list_ref);
        CFRelease(space_ref);
        
        if (!ids_only) {
            fprintf(rsp, "\n=== End Space Iterator Data ===\n");
        }
    }
    else if (strcmp(test_func, "window_iterator_data") == 0) {
        // Check if we should only print IDs or JSON
        bool ids_only = (args && strcmp(args, "ids_only") == 0);
        bool json_output = !ids_only; // Default to JSON unless ids_only specified
        
        // Get space ID from args or use active space
        uint64_t sid = 0;
        
        if (args && *args && !ids_only) {
            sid = strtoull(args, NULL, 10);
        }
        
        if (sid == 0) {
            sid = space_manager_active_space();
        }
        
        // Get all windows for this space
        uint64_t set_tags = 0;
        uint64_t clear_tags = 0;
        CFArrayRef space_ref = cfarray_of_cfnumbers(&sid, sizeof(uint64_t), 1, kCFNumberSInt64Type);
        CFArrayRef window_list_ref = SLSCopyWindowsWithOptionsAndTags(g_connection, 0, space_ref, 0x7, &set_tags, &clear_tags);
        
        if (!window_list_ref) {
            if (json_output) {
                fprintf(rsp, "{\"error\":\"SLSCopyWindowsWithOptionsAndTags returned NULL\"}\n");
            } else {
                fprintf(rsp, "ERROR: SLSCopyWindowsWithOptionsAndTags returned NULL\n");
            }
            CFRelease(space_ref);
            return;
        }
        
        int window_count = CFArrayGetCount(window_list_ref);
        
        if (window_count == 0) {
            if (json_output) {
                fprintf(rsp, "{\"space_id\":%llu,\"windows\":[]}\n", sid);
            } else {
                fprintf(rsp, "No windows on this space\n");
            }
            CFRelease(window_list_ref);
            CFRelease(space_ref);
            return;
        }
        
        // Create window query
        CFTypeRef query = SLSWindowQueryWindows(g_connection, window_list_ref, window_count);
        if (!query) {
            if (json_output) {
                fprintf(rsp, "{\"error\":\"SLSWindowQueryWindows failed\"}\n");
            } else {
                fprintf(rsp, "ERROR: SLSWindowQueryWindows failed\n");
            }
            CFRelease(window_list_ref);
            CFRelease(space_ref);
            return;
        }
        
        // Get window iterator
        CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);
        if (!iterator) {
            if (json_output) {
                fprintf(rsp, "{\"error\":\"SLSWindowQueryResultCopyWindows failed\"}\n");
            } else {
                fprintf(rsp, "ERROR: SLSWindowQueryResultCopyWindows failed\n");
            }
            CFRelease(query);
            CFRelease(window_list_ref);
            CFRelease(space_ref);
            return;
        }
        
        int iter_count = SLSWindowIteratorGetCount(iterator);
        
        if (json_output) {
            fprintf(rsp, "{\n");
            fprintf(rsp, "  \"space_id\": %llu,\n", sid);
            fprintf(rsp, "  \"window_count\": %d,\n", iter_count);
            fprintf(rsp, "  \"windows\": [\n");
        }
        
        int window_index = 0;
        while (SLSWindowIteratorAdvance(iterator)) {
            if (ids_only) {
                // Just print the window ID
                fprintf(rsp, "%u\n", SLSWindowIteratorGetWindowID(iterator));
                window_index++;
                continue;
            }
            
            // JSON output
            if (window_index > 0) fprintf(rsp, ",\n");
            
            fprintf(rsp, "    {\n");
            
            uint32_t wid = SLSWindowIteratorGetWindowID(iterator);
            fprintf(rsp, "      \"window_id\": %u,\n", wid);
            fprintf(rsp, "      \"owner\": %u,\n", SLSWindowIteratorGetOwner(iterator));
            fprintf(rsp, "      \"parent_id\": %u,\n", SLSWindowIteratorGetParentID(iterator));
            fprintf(rsp, "      \"pid\": %d,\n", SLSWindowIteratorGetPID(iterator));
            fprintf(rsp, "      \"level\": %d,\n", SLSWindowIteratorGetLevel(iterator));
            
            int sublevel = SLSGetWindowSubLevel(g_connection, wid);
            fprintf(rsp, "      \"sublevel\": %d,\n", sublevel);
            
            fprintf(rsp, "      \"alpha\": %.2f,\n", SLSWindowIteratorGetAlpha(iterator));
            
            // Title - need to escape JSON strings
            CFStringRef title = SLSWindowIteratorCopyTitle(iterator);
            fprintf(rsp, "      \"title\": ");
            if (title) {
                // Try to get C string pointer first (faster)
                const char *title_cstr = CFStringGetCStringPtr(title, kCFStringEncodingUTF8);
                char buffer[256];
                const char *final_str = NULL;
                
                if (title_cstr) {
                    final_str = title_cstr;
                } else if (CFStringGetCString(title, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
                    final_str = buffer;
                }
                
                if (final_str && final_str[0] != '\0') {
                    // Escape special characters for JSON
                    fprintf(rsp, "\"");
                    for (const char *p = final_str; *p; p++) {
                        if (*p == '"') fprintf(rsp, "\\\"");
                        else if (*p == '\\') fprintf(rsp, "\\\\");
                        else if (*p == '\n') fprintf(rsp, "\\n");
                        else if (*p == '\r') fprintf(rsp, "\\r");
                        else if (*p == '\t') fprintf(rsp, "\\t");
                        else fprintf(rsp, "%c", *p);
                    }
                    fprintf(rsp, "\"");
                } else {
                    // Empty string
                    fprintf(rsp, "\"\"");
                }
                CFRelease(title);
            } else {
                fprintf(rsp, "null");
            }
            fprintf(rsp, ",\n");
            
            fprintf(rsp, "      \"tags\": \"0x%016llx\",\n", SLSWindowIteratorGetTags(iterator));
            fprintf(rsp, "      \"attributes\": \"0x%016llx\",\n", SLSWindowIteratorGetAttributes(iterator));
            fprintf(rsp, "      \"space_count\": %d,\n", SLSWindowIteratorGetSpaceCount(iterator));
            fprintf(rsp, "      \"matching_space_id\": %llu,\n", SLSWindowIteratorGetMatchingSpaceID(iterator));
            fprintf(rsp, "      \"space_attributes\": \"0x%08x\",\n", SLSWindowIteratorGetSpaceAttributes(iterator));
            fprintf(rsp, "      \"space_type_mask\": \"0x%08x\"\n", SLSWindowIteratorGetSpaceTypeMask(iterator));
            
            fprintf(rsp, "    }");
            window_index++;
        }
        
        if (json_output) {
            fprintf(rsp, "\n  ]\n");
            fprintf(rsp, "}\n");
        }
        
        CFRelease(iterator);
        CFRelease(query);
        CFRelease(window_list_ref);
        CFRelease(space_ref);
    }
    else if (strcmp(test_func, "stage_manager_windows") == 0) {
        // Hunt for Stage Manager specific windows and track changes
        uint64_t sid = 0;
        
        if (args && *args && strcmp(args, "diff") != 0) {
            sid = strtoull(args, NULL, 10);
        }
        
        if (sid == 0) {
            sid = space_manager_active_space();
        }
        
        fprintf(rsp, "=== Stage Manager Window Hunter ===\n\n");
        fprintf(rsp, "Space ID: %llu\n\n", sid);
        
        // Get all windows for this space
        uint64_t set_tags = 0;
        uint64_t clear_tags = 0;
        CFArrayRef space_ref = cfarray_of_cfnumbers(&sid, sizeof(uint64_t), 1, kCFNumberSInt64Type);
        CFArrayRef window_list_ref = SLSCopyWindowsWithOptionsAndTags(g_connection, 0, space_ref, 0x7, &set_tags, &clear_tags);
        
        if (!window_list_ref) {
            fprintf(rsp, "ERROR: SLSCopyWindowsWithOptionsAndTags returned NULL\n");
            CFRelease(space_ref);
            return;
        }
        
        int window_count = CFArrayGetCount(window_list_ref);
        fprintf(rsp, "Total windows: %d\n\n", window_count);
        
        if (window_count == 0) {
            CFRelease(window_list_ref);
            CFRelease(space_ref);
            return;
        }
        
        // Create window query
        CFTypeRef query = SLSWindowQueryWindows(g_connection, window_list_ref, window_count);
        if (!query) {
            fprintf(rsp, "ERROR: SLSWindowQueryWindows failed\n");
            CFRelease(window_list_ref);
            CFRelease(space_ref);
            return;
        }
        
        CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);
        if (!iterator) {
            fprintf(rsp, "ERROR: SLSWindowQueryResultCopyWindows failed\n");
            CFRelease(query);
            CFRelease(window_list_ref);
            CFRelease(space_ref);
            return;
        }
        
        fprintf(rsp, "🔍 Searching for Stage Manager windows...\n\n");
        
        int app_icon_count = 0;
        int gesture_overlay_count = 0;
        int other_count = 0;
        
        while (SLSWindowIteratorAdvance(iterator)) {
            CFStringRef title = SLSWindowIteratorCopyTitle(iterator);
            if (title) {
                char buffer[256];
                bool got_title = CFStringGetCString(title, buffer, sizeof(buffer), kCFStringEncodingUTF8);
                
                if (got_title) {
                    // Check for Stage Manager specific windows
                    if (strstr(buffer, "App Icon Window")) {
                        fprintf(rsp, "🎯 APP ICON WINDOW #%d\n", ++app_icon_count);
                        fprintf(rsp, "   WID: %u\n", SLSWindowIteratorGetWindowID(iterator));
                        fprintf(rsp, "   Title: %s\n", buffer);
                        fprintf(rsp, "   Level: %d\n", SLSWindowIteratorGetLevel(iterator));
                        fprintf(rsp, "   Alpha: %.2f\n", SLSWindowIteratorGetAlpha(iterator));
                        fprintf(rsp, "   Tags: 0x%016llx\n", SLSWindowIteratorGetTags(iterator));
                        fprintf(rsp, "   Attributes: 0x%016llx\n", SLSWindowIteratorGetAttributes(iterator));
                        
                        CGRect bounds = SLSWindowIteratorGetBounds(iterator);
                        fprintf(rsp, "   Bounds: {{%.0f, %.0f}, {%.0f, %.0f}}\n",
                                bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);
                        
                        fprintf(rsp, "   SpaceCount: %d\n", SLSWindowIteratorGetSpaceCount(iterator));
                        fprintf(rsp, "   ParentID: %u\n", SLSWindowIteratorGetParentID(iterator));
                        fprintf(rsp, "\n");
                    }
                    else if (strstr(buffer, "Gesture Blocking Overlay")) {
                        fprintf(rsp, "🛡️  GESTURE BLOCKING OVERLAY #%d\n", ++gesture_overlay_count);
                        fprintf(rsp, "   WID: %u\n", SLSWindowIteratorGetWindowID(iterator));
                        fprintf(rsp, "   Title: %s\n", buffer);
                        fprintf(rsp, "   Level: %d\n", SLSWindowIteratorGetLevel(iterator));
                        fprintf(rsp, "   Alpha: %.2f\n", SLSWindowIteratorGetAlpha(iterator));
                        fprintf(rsp, "   Tags: 0x%016llx\n", SLSWindowIteratorGetTags(iterator));
                        fprintf(rsp, "   Attributes: 0x%016llx\n", SLSWindowIteratorGetAttributes(iterator));
                        
                        CGRect bounds = SLSWindowIteratorGetBounds(iterator);
                        fprintf(rsp, "   Bounds: {{%.0f, %.0f}, {%.0f, %.0f}}\n",
                                bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);
                        
                        fprintf(rsp, "   ParentID: %u\n", SLSWindowIteratorGetParentID(iterator));
                        
                        // Check attached windows
                        int attached_count = SLSWindowIteratorGetAttachedWindowCount(iterator);
                        fprintf(rsp, "   AttachedWindowCount: %d\n", attached_count);
                        if (attached_count > 0) {
                            CFArrayRef attached = SLSWindowIteratorCopyAttachedWindows(iterator);
                            if (attached) {
                                fprintf(rsp, "   AttachedIDs: [");
                                for (int i = 0; i < attached_count; i++) {
                                    CFNumberRef wid_num = CFArrayGetValueAtIndex(attached, i);
                                    uint32_t attached_wid;
                                    CFNumberGetValue(wid_num, kCFNumberSInt32Type, &attached_wid);
                                    fprintf(rsp, "%u%s", attached_wid, (i < attached_count - 1) ? ", " : "");
                                }
                                fprintf(rsp, "]\n");
                                CFRelease(attached);
                            }
                        }
                        fprintf(rsp, "\n");
                    }
                    else if (strlen(buffer) > 0) {
                        other_count++;
                    }
                }
                CFRelease(title);
            }
        }
        
        fprintf(rsp, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
        fprintf(rsp, "Summary:\n");
        fprintf(rsp, "  App Icon Windows:        %d\n", app_icon_count);
        fprintf(rsp, "  Gesture Blocking Overlay: %d\n", gesture_overlay_count);
        fprintf(rsp, "  Other windows:           %d\n", other_count);
        fprintf(rsp, "\n");
        fprintf(rsp, "💡 Note: Hover over Stage Manager icons to see 5 extra windows appear (221x IDs)\n");
        
        CFRelease(iterator);
        CFRelease(query);
        CFRelease(window_list_ref);
        CFRelease(space_ref);
        
        fprintf(rsp, "\n=== End Stage Manager Window Hunter ===\n");
    }
    else if (strcmp(test_func, "window_group") == 0) {
        // Test window group for a specific window ID
        // Usage: yabai -m debug --test-api window_group <WID>
        // If no WID provided, uses focused window from SLS
        
        uint32_t wid = 0;
        
        if (args && *args) {
            wid = (uint32_t)strtoul(args, NULL, 10);
        } else {
            // Window ID is required
            fprintf(rsp, "ERROR: Window ID required\n");
            fprintf(rsp, "Usage: yabai -m debug --test-api window_group <WID>\n");
            fprintf(rsp, "\nTip: Use 'yabai -m debug --test-api window_iterator_data ids_only' to list window IDs\n");
            return;
        }
        
        if (wid == 0) {
            fprintf(rsp, "ERROR: No window ID provided\n");
            fprintf(rsp, "Usage: yabai -m debug --test-api window_group <WID>\n");
            return;
        }
        
        fprintf(rsp, "=== Window Group Test ===\n\n");
        fprintf(rsp, "Window ID: %u\n\n", wid);
        
        // The actual SLSCopyWindowGroup signature (reverse engineered):
        // Returns 0 on success.
        // On success: *out_ids points to a malloc'd array you must free; *out_count is element count.
        typedef int (*SLSCopyWindowGroup_t)(uint32_t window_id, CFStringRef which_group, uint32_t **out_ids, uint32_t *out_count);
        
        // Cast to the correct signature (extern.h has wrong signature)
        SLSCopyWindowGroup_t _SLSCopyWindowGroup = (SLSCopyWindowGroup_t)SLSCopyWindowGroup;
        
        // Test orderingGroup
        fprintf(rsp, "OrderingGroup:\n");
        uint32_t *ordering_ids = NULL;
        uint32_t ordering_count = 0;
        int result = _SLSCopyWindowGroup(wid, CFSTR("orderingGroup"), &ordering_ids, &ordering_count);
        
        fprintf(rsp, "  Result: %d", result);
        if (result == 0) fprintf(rsp, " (success)");
        fprintf(rsp, "\n");
        fprintf(rsp, "  Count:  %u\n", ordering_count);
        
        if (ordering_ids && ordering_count > 0) {
            fprintf(rsp, "  Windows: [");
            for (uint32_t j = 0; j < ordering_count && j < 20; j++) {
                fprintf(rsp, "%u%s", ordering_ids[j], (j < ordering_count - 1) ? ", " : "");
            }
            if (ordering_count > 20) fprintf(rsp, " ... (%u more)", ordering_count - 20);
            fprintf(rsp, "]\n");
            free(ordering_ids);
        } else {
            fprintf(rsp, "  Windows: (none)\n");
        }
        fprintf(rsp, "\n");
        
        // Test movementGroup
        fprintf(rsp, "MovementGroup:\n");
        uint32_t *movement_ids = NULL;
        uint32_t movement_count = 0;
        result = _SLSCopyWindowGroup(wid, CFSTR("movementGroup"), &movement_ids, &movement_count);
        
        fprintf(rsp, "  Result: %d", result);
        if (result == 0) fprintf(rsp, " (success)");
        fprintf(rsp, "\n");
        fprintf(rsp, "  Count:  %u\n", movement_count);
        
        if (movement_ids && movement_count > 0) {
            fprintf(rsp, "  Windows: [");
            for (uint32_t j = 0; j < movement_count && j < 20; j++) {
                fprintf(rsp, "%u%s", movement_ids[j], (j < movement_count - 1) ? ", " : "");
            }
            if (movement_count > 20) fprintf(rsp, " ... (%u more)", movement_count - 20);
            fprintf(rsp, "]\n");
            free(movement_ids);
        } else {
            fprintf(rsp, "  Windows: (none)\n");
        }
        fprintf(rsp, "\n");
        
        fprintf(rsp, "=== End Window Group Test ===\n");
    }

    else if (strcmp(test_func, "compare_snapshots") == 0) {
        // Take two snapshots with a delay and compare them
        int delay_seconds = 5;
        
        // Parse custom delay if provided
        if (args && *args) {
            delay_seconds = atoi(args);
            if (delay_seconds <= 0) delay_seconds = 5;
        }
        
        fprintf(rsp, "=== Compare Window Snapshots ===\n\n");
        fprintf(rsp, "📸 Taking SNAPSHOT 1...\n");
        
        uint64_t sid = space_manager_active_space();
        
        // Snapshot 1
        uint64_t set_tags_1 = 0;
        uint64_t clear_tags_1 = 0;
        CFArrayRef space_ref_1 = cfarray_of_cfnumbers(&sid, sizeof(uint64_t), 1, kCFNumberSInt64Type);
        CFArrayRef window_list_1 = SLSCopyWindowsWithOptionsAndTags(g_connection, 0, space_ref_1, 0x7, &set_tags_1, &clear_tags_1);
        
        if (!window_list_1) {
            fprintf(rsp, "ERROR: SLSCopyWindowsWithOptionsAndTags returned NULL for snapshot 1\n");
            CFRelease(space_ref_1);
            return;
        }
        
        int count_1 = CFArrayGetCount(window_list_1);
        
        // Store snapshot 1 data
        typedef struct {
            uint32_t wid;
            int level;
            uint64_t tags;
            float alpha;
            char title[256];
        } WindowSnapshot;
        
        WindowSnapshot *snapshot_1 = malloc(sizeof(WindowSnapshot) * count_1);
        if (!snapshot_1) {
            fprintf(rsp, "ERROR: Failed to allocate memory for snapshot 1\n");
            CFRelease(window_list_1);
            CFRelease(space_ref_1);
            return;
        }
        
        // Create query for snapshot 1
        CFTypeRef query_1 = SLSWindowQueryWindows(g_connection, window_list_1, count_1);
        if (query_1) {
            CFTypeRef iterator_1 = SLSWindowQueryResultCopyWindows(query_1);
            if (iterator_1) {
                int idx = 0;
                while (SLSWindowIteratorAdvance(iterator_1) && idx < count_1) {
                    snapshot_1[idx].wid = SLSWindowIteratorGetWindowID(iterator_1);
                    snapshot_1[idx].level = SLSWindowIteratorGetLevel(iterator_1);
                    snapshot_1[idx].tags = SLSWindowIteratorGetTags(iterator_1);
                    snapshot_1[idx].alpha = SLSWindowIteratorGetAlpha(iterator_1);
                    
                    CFStringRef title_ref = SLSWindowIteratorCopyTitle(iterator_1);
                    if (title_ref) {
                        CFStringGetCString(title_ref, snapshot_1[idx].title, sizeof(snapshot_1[idx].title), kCFStringEncodingUTF8);
                        CFRelease(title_ref);
                    } else {
                        strcpy(snapshot_1[idx].title, "(no title)");
                    }
                    idx++;
                }
                CFRelease(iterator_1);
            }
            CFRelease(query_1);
        }
        
        CFRelease(window_list_1);
        CFRelease(space_ref_1);
        
        fprintf(rsp, "   Captured %d windows\n\n", count_1);
        fprintf(rsp, "⏳ Waiting %d seconds for changes...\n", delay_seconds);
        fprintf(rsp, "   (Hover over Stage Manager icons, move windows, etc.)\n\n");
        fflush(rsp);
        
        // Wait
        sleep(delay_seconds);
        
        fprintf(rsp, "📸 Taking SNAPSHOT 2...\n");
        
        // Snapshot 2
        uint64_t set_tags_2 = 0;
        uint64_t clear_tags_2 = 0;
        CFArrayRef space_ref_2 = cfarray_of_cfnumbers(&sid, sizeof(uint64_t), 1, kCFNumberSInt64Type);
        CFArrayRef window_list_2 = SLSCopyWindowsWithOptionsAndTags(g_connection, 0, space_ref_2, 0x7, &set_tags_2, &clear_tags_2);
        
        if (!window_list_2) {
            fprintf(rsp, "ERROR: SLSCopyWindowsWithOptionsAndTags returned NULL for snapshot 2\n");
            CFRelease(space_ref_2);
            free(snapshot_1);
            return;
        }
        
        int count_2 = CFArrayGetCount(window_list_2);
        
        WindowSnapshot *snapshot_2 = malloc(sizeof(WindowSnapshot) * count_2);
        if (!snapshot_2) {
            fprintf(rsp, "ERROR: Failed to allocate memory for snapshot 2\n");
            CFRelease(window_list_2);
            CFRelease(space_ref_2);
            free(snapshot_1);
            return;
        }
        
        // Create query for snapshot 2
        CFTypeRef query_2 = SLSWindowQueryWindows(g_connection, window_list_2, count_2);
        if (query_2) {
            CFTypeRef iterator_2 = SLSWindowQueryResultCopyWindows(query_2);
            if (iterator_2) {
                int idx = 0;
                while (SLSWindowIteratorAdvance(iterator_2) && idx < count_2) {
                    snapshot_2[idx].wid = SLSWindowIteratorGetWindowID(iterator_2);
                    snapshot_2[idx].level = SLSWindowIteratorGetLevel(iterator_2);
                    snapshot_2[idx].tags = SLSWindowIteratorGetTags(iterator_2);
                    snapshot_2[idx].alpha = SLSWindowIteratorGetAlpha(iterator_2);
                    
                    CFStringRef title_ref = SLSWindowIteratorCopyTitle(iterator_2);
                    if (title_ref) {
                        CFStringGetCString(title_ref, snapshot_2[idx].title, sizeof(snapshot_2[idx].title), kCFStringEncodingUTF8);
                        CFRelease(title_ref);
                    } else {
                        strcpy(snapshot_2[idx].title, "(no title)");
                    }
                    idx++;
                }
                CFRelease(iterator_2);
            }
            CFRelease(query_2);
        }
        
        CFRelease(window_list_2);
        CFRelease(space_ref_2);
        
        fprintf(rsp, "   Captured %d windows\n\n", count_2);
        
        // Compare and display
        fprintf(rsp, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
        fprintf(rsp, "COMPARISON RESULTS\n");
        fprintf(rsp, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n");
        
        fprintf(rsp, "Window Count Change: %d → %d", count_1, count_2);
        if (count_2 > count_1) {
            fprintf(rsp, " 🔥 (+%d NEW WINDOWS!)", count_2 - count_1);
        } else if (count_2 < count_1) {
            fprintf(rsp, " ⚠️  (-%d windows removed)", count_1 - count_2);
        }
        fprintf(rsp, "\n\n");
        
        // Find new windows (in snapshot 2 but not in snapshot 1)
        fprintf(rsp, "🆕 NEW WINDOWS:\n");
        int new_count = 0;
        for (int i = 0; i < count_2; i++) {
            bool found = false;
            for (int j = 0; j < count_1; j++) {
                if (snapshot_2[i].wid == snapshot_1[j].wid) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                new_count++;
                fprintf(rsp, "   [%d] WID %u | Level %d | Alpha %.2f | Tags 0x%llx\n",
                        new_count, snapshot_2[i].wid, snapshot_2[i].level, 
                        snapshot_2[i].alpha, snapshot_2[i].tags);
                fprintf(rsp, "       Title: %s\n", snapshot_2[i].title);
            }
        }
        if (new_count == 0) {
            fprintf(rsp, "   None\n");
        }
        fprintf(rsp, "\n");
        
        // Find removed windows (in snapshot 1 but not in snapshot 2)
        fprintf(rsp, "🗑️  REMOVED WINDOWS:\n");
        int removed_count = 0;
        for (int i = 0; i < count_1; i++) {
            bool found = false;
            for (int j = 0; j < count_2; j++) {
                if (snapshot_1[i].wid == snapshot_2[j].wid) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                removed_count++;
                fprintf(rsp, "   [%d] WID %u | Level %d | Alpha %.2f | Tags 0x%llx\n",
                        removed_count, snapshot_1[i].wid, snapshot_1[i].level,
                        snapshot_1[i].alpha, snapshot_1[i].tags);
                fprintf(rsp, "       Title: %s\n", snapshot_1[i].title);
            }
        }
        if (removed_count == 0) {
            fprintf(rsp, "   None\n");
        }
        fprintf(rsp, "\n");
        
        // Find changed windows (same WID but different properties)
        fprintf(rsp, "🔄 CHANGED WINDOWS:\n");
        int changed_count = 0;
        for (int i = 0; i < count_2; i++) {
            for (int j = 0; j < count_1; j++) {
                if (snapshot_2[i].wid == snapshot_1[j].wid) {
                    // Check for changes
                    bool changed = false;
                    char changes[512] = "";
                    
                    if (snapshot_2[i].level != snapshot_1[j].level) {
                        sprintf(changes + strlen(changes), "Level: %d→%d  ", 
                                snapshot_1[j].level, snapshot_2[i].level);
                        changed = true;
                    }
                    if (snapshot_2[i].alpha != snapshot_1[j].alpha) {
                        sprintf(changes + strlen(changes), "Alpha: %.2f→%.2f  ", 
                                snapshot_1[j].alpha, snapshot_2[i].alpha);
                        changed = true;
                    }
                    if (snapshot_2[i].tags != snapshot_1[j].tags) {
                        sprintf(changes + strlen(changes), "Tags: 0x%llx→0x%llx  ", 
                                snapshot_1[j].tags, snapshot_2[i].tags);
                        changed = true;
                    }
                    if (strcmp(snapshot_2[i].title, snapshot_1[j].title) != 0) {
                        sprintf(changes + strlen(changes), "Title changed  ");
                        changed = true;
                    }
                    
                    if (changed) {
                        changed_count++;
                        fprintf(rsp, "   [%d] WID %u:\n", changed_count, snapshot_2[i].wid);
                        fprintf(rsp, "       Changes: %s\n", changes);
                        fprintf(rsp, "       Title: %s\n", snapshot_2[i].title);
                    }
                    break;
                }
            }
        }
        if (changed_count == 0) {
            fprintf(rsp, "   None\n");
        }
        
        fprintf(rsp, "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
        fprintf(rsp, "Summary:\n");
        fprintf(rsp, "  New windows:     %d\n", new_count);
        fprintf(rsp, "  Removed windows: %d\n", removed_count);
        fprintf(rsp, "  Changed windows: %d\n", changed_count);
        fprintf(rsp, "  Unchanged:       %d\n", count_2 - new_count - changed_count);
        
        free(snapshot_1);
        free(snapshot_2);
        
        fprintf(rsp, "\n=== End Compare Window Snapshots ===\n");
    }

}