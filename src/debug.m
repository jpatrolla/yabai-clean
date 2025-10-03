#include "debug.h"
#include "misc/extern.h"
#include "misc/macho_dlsym.h"

// External globals needed for debug functions
extern int g_connection;

void debug_log_test(FILE *rsp)
{
    fprintf(rsp, "🔍 Testing SkyLight Window Iterator APIs...\n\n");
    
    // Get all displays to test with
    CFArrayRef display_list = SLSCopyManagedDisplays(g_connection);
    if (!display_list) {
        fprintf(rsp, "❌ Failed to get display list\n");
        return;
    }
    
    fprintf(rsp, "📺 Found %ld displays\n", CFArrayGetCount(display_list));
    
    // Test basic window enumeration
    @try {
        CFArrayRef window_list = SLSCopyWindowsWithOptionsAndTags(g_connection, 0, NULL, 2, NULL, NULL);
        if (window_list) {
            CFIndex count = CFArrayGetCount(window_list);
            fprintf(rsp, "🪟 Found %ld windows using SLSCopyWindowsWithOptionsAndTags\n", count);
            
            if (count > 0) {
                // Test window query and iterator
                CFTypeRef query = SLSWindowQueryWindows(g_connection, window_list, (int)count);
                if (query) {
                    fprintf(rsp, "✅ SLSWindowQueryWindows succeeded\n");
                    
                    CFTypeRef window_list_ref = SLSWindowQueryResultCopyWindows(query);
                    if (window_list_ref) {
                        fprintf(rsp, "✅ SLSWindowQueryResultCopyWindows succeeded\n");
                        
                        CFTypeRef iterator = SLSWindowIteratorCreate(window_list_ref);
                        if (iterator) {
                            fprintf(rsp, "✅ SLSWindowIteratorCreate succeeded\n");
                            fprintf(rsp, "🔄 Testing iterator functions...\n");
                            
                            int window_count = 0;
                            do {
                                uint32_t wid = SLSWindowIteratorGetWindowID(iterator);
                                uint64_t tags = SLSWindowIteratorGetTags(iterator);
                                uint32_t level = SLSWindowIteratorGetLevel(iterator);
                                CGRect bounds = SLSWindowIteratorGetBounds(iterator);
                                uint32_t owner = SLSWindowIteratorGetOwner(iterator);
                                
                                CFStringRef title = SLSWindowIteratorCopyTitle(iterator);
                                const char* title_str = title ? CFStringGetCStringPtr(title, kCFStringEncodingUTF8) : "NULL";
                                if (!title_str && title) {
                                    // Fallback for non-ASCII titles
                                    title_str = "Non-ASCII";
                                }
                                
                                fprintf(rsp, "  Window %d: ID=%u, Tags=0x%llx, Level=%u, Owner=%u, Title=%s\n", 
                                       window_count, wid, tags, level, owner, title_str ? title_str : "NULL");
                                fprintf(rsp, "             Bounds={{%.0f,%.0f},{%.0f,%.0f}}\n",
                                       bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);
                                
                                if (title) CFRelease(title);
                                window_count++;
                                
                                // Limit output to first 10 windows
                                if (window_count >= 10) {
                                    fprintf(rsp, "  ... (showing first 10 windows)\n");
                                    break;
                                }
                            } while (SLSWindowIteratorAdvance(iterator));
                            
                            fprintf(rsp, "📊 Total windows processed: %d\n", window_count);
                            CFRelease(iterator);
                        } else {
                            fprintf(rsp, "❌ SLSWindowIteratorCreate failed\n");
                        }
                        
                        CFRelease(window_list_ref);
                    } else {
                        fprintf(rsp, "❌ SLSWindowQueryResultCopyWindows failed\n");
                    }
                    
                    CFRelease(query);
                } else {
                    fprintf(rsp, "❌ SLSWindowQueryWindows failed\n");
                }
            }
            
            CFRelease(window_list);
        } else {
            fprintf(rsp, "❌ SLSCopyWindowsWithOptionsAndTags failed\n");
        }
    } @catch (NSException *e) {
        fprintf(rsp, "💥 Exception during window iterator test: %s\n", [[e reason] UTF8String]);
    }
    
    CFRelease(display_list);
    fprintf(rsp, "\n✨ Window iterator test completed!\n");
}

void debug_call_api(FILE *rsp)
{
    fprintf(rsp, "🧪 Testing flexible API calling with macho_find_symbol...\n\n");
    
    // Test if we can dynamically find and call SkyLight functions
    void *skylight_handle = NULL;
    
    // Try to get SkyLight framework handle
    @try {
        // Test basic function availability
        void *copy_windows_func = macho_find_symbol("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", 
                                                   "_SLSCopyWindowsWithOptionsAndTags");
        if (copy_windows_func) {
            fprintf(rsp, "✅ Found SLSCopyWindowsWithOptionsAndTags at %p\n", copy_windows_func);
        } else {
            fprintf(rsp, "❌ Could not find SLSCopyWindowsWithOptionsAndTags\n");
        }
        
        void *window_query_func = macho_find_symbol("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", 
                                                   "_SLSWindowQueryWindows");
        if (window_query_func) {
            fprintf(rsp, "✅ Found SLSWindowQueryWindows at %p\n", window_query_func);
        } else {
            fprintf(rsp, "❌ Could not find SLSWindowQueryWindows\n");
        }
        
        // Test iterator functions
        void *iterator_create_func = macho_find_symbol("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", 
                                                      "_SLSWindowIteratorCreate");
        if (iterator_create_func) {
            fprintf(rsp, "✅ Found SLSWindowIteratorCreate at %p\n", iterator_create_func);
        } else {
            fprintf(rsp, "❌ Could not find SLSWindowIteratorCreate\n");
        }
        
        // Test space query functions
        void *space_count_func = macho_find_symbol("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", 
                                                  "__SLSWindowQueryResultGetSpaceCount");
        if (space_count_func) {
            fprintf(rsp, "✅ Found _SLSWindowQueryResultGetSpaceCount at %p\n", space_count_func);
        } else {
            fprintf(rsp, "❌ Could not find _SLSWindowQueryResultGetSpaceCount\n");
        }
        
        void *copy_spaces_func = macho_find_symbol("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", 
                                                  "__SLSWindowQueryResultCopySpaces");
        if (copy_spaces_func) {
            fprintf(rsp, "✅ Found _SLSWindowQueryResultCopySpaces at %p\n", copy_spaces_func);
        } else {
            fprintf(rsp, "❌ Could not find _SLSWindowQueryResultCopySpaces\n");
        }
        
        // Test display iterator functions (these might not exist)
        void *display_query_func = macho_find_symbol("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", 
                                                    "_SLSManagedDisplayQueryCreate");
        if (display_query_func) {
            fprintf(rsp, "🔥 Found SLSManagedDisplayQueryCreate at %p (DISPLAY ITERATOR EXISTS!)\n", display_query_func);
        } else {
            fprintf(rsp, "⚠️  Could not find SLSManagedDisplayQueryCreate (expected)\n");
        }
        
        void *managed_spaces_func = macho_find_symbol("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", 
                                                     "_SLSManagedDisplayIteratorCopyManagedSpaces");
        if (managed_spaces_func) {
            fprintf(rsp, "🚀 Found SLSManagedDisplayIteratorCopyManagedSpaces at %p (STAGE MANAGER FUNCTION!)\n", managed_spaces_func);
        } else {
            fprintf(rsp, "⚠️  Could not find SLSManagedDisplayIteratorCopyManagedSpaces\n");
        }
        
        fprintf(rsp, "\n📝 Summary: Use this function to safely test if Stage Manager APIs exist!\n");
        
    } @catch (NSException *e) {
        fprintf(rsp, "💥 Exception during API testing: %s\n", [[e reason] UTF8String]);
    }
    
    fprintf(rsp, "\n✨ API availability test completed!\n");
}