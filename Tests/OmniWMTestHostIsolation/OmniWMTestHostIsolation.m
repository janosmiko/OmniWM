// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#import "OmniWMTestHostIsolation.h"
#import <objc/runtime.h>
#import <string.h>

extern char **environ;
extern void test_isolate_host(void);

static BOOL isolated;
static const void *visibleKey = &visibleKey;
static __weak NSWindow *requestedKeyWindow;

BOOL OmniWMTestHostIsIsolated(void) {
    return isolated;
}

BOOL OmniWMTestWindowIsKey(NSWindow *window) {
    return isolated ? requestedKeyWindow == window : window.isKeyWindow;
}

static const char *liveTestGate(void) {
    for (char **entry = environ; *entry != NULL; entry++) {
        const char *value = strchr(*entry, '=');
        if (strncmp(*entry, "OMNIWM_RUN_", strlen("OMNIWM_RUN_")) == 0 && value != NULL && strcmp(value, "=1") == 0) {
            return *entry;
        }
    }
    return NULL;
}

static IMP replace(Class cls, SEL selector, id block) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        fprintf(stderr, "OmniWMTestHostIsolation: missing %s\n", sel_getName(selector));
        return NULL;
    }
    return method_setImplementation(method, imp_implementationWithBlock(block));
}

static void setVisible(NSWindow *window, BOOL visible) {
    objc_setAssociatedObject(window, visibleKey, @(visible), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!visible && requestedKeyWindow == window) {
        requestedKeyWindow = nil;
    }
}

static NSNumber *recordedVisibility(NSWindow *window) {
    return objc_getAssociatedObject(window, visibleKey);
}

static void installSwizzles(void) {
    __block IMP setPolicy = replace(NSApplication.class, @selector(setActivationPolicy:),
        ^BOOL(NSApplication *app, NSApplicationActivationPolicy policy) {
            if (policy != NSApplicationActivationPolicyProhibited) {
                return NO;
            }
            return ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))setPolicy)(
                app, @selector(setActivationPolicy:), policy);
        });
    replace(NSRunningApplication.class, @selector(activateWithOptions:),
        ^BOOL(NSRunningApplication *app, NSApplicationActivationOptions options) {
            return NO;
        });
    replace(NSWindow.class, @selector(makeKeyWindow), ^(NSWindow *window) {
        if (window.canBecomeKeyWindow) {
            requestedKeyWindow = window;
        }
    });
    replace(NSWindow.class, @selector(resignKeyWindow), ^(NSWindow *window) {
        if (requestedKeyWindow == window) {
            requestedKeyWindow = nil;
        }
    });
    __block IMP orderWindow = replace(NSWindow.class, @selector(orderWindow:relativeTo:),
        ^(NSWindow *window, NSWindowOrderingMode place, NSInteger otherWindow) {
            setVisible(window, place != NSWindowOut);
            if (place == NSWindowOut) {
                ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))orderWindow)(
                    window, @selector(orderWindow:relativeTo:), place, otherWindow);
            }
        });
    replace(NSWindow.class, @selector(orderFrontRegardless), ^(NSWindow *window) {
        setVisible(window, YES);
    });
    __block IMP isVisible = replace(NSWindow.class, @selector(isVisible), ^BOOL(NSWindow *window) {
        NSNumber *visible = recordedVisibility(window);
        return visible ? visible.boolValue : ((BOOL (*)(id, SEL))isVisible)(window, @selector(isVisible));
    });
    __block IMP isOnActiveSpace = replace(NSWindow.class, @selector(isOnActiveSpace), ^BOOL(NSWindow *window) {
        return recordedVisibility(window).boolValue
            || ((BOOL (*)(id, SEL))isOnActiveSpace)(window, @selector(isOnActiveSpace));
    });
    __block IMP close = replace(NSWindow.class, @selector(close), ^(NSWindow *window) {
        setVisible(window, NO);
        ((void (*)(id, SEL))close)(window, @selector(close));
    });
    // The second button is the cancel choice by AppKit convention, so prompts never confirm a destructive action.
    replace(NSAlert.class, @selector(runModal), ^NSModalResponse(NSAlert *alert) {
        return alert.buttons.count >= 2 ? NSAlertSecondButtonReturn : NSAlertFirstButtonReturn;
    });
    replace(NSMenu.class, @selector(popUpMenuPositioningItem:atLocation:inView:),
        ^BOOL(NSMenu *menu, NSMenuItem *item, NSPoint location, NSView *view) {
            return NO;
        });
}

// An enabled OMNIWM_RUN_* gate means the developer asked for live checks against the real window server.
__attribute__((constructor)) static void isolateHost(void) {
    const char *gate = liveTestGate();
    if (gate != NULL) {
        fprintf(stderr, "OmniWMTestHostIsolation: off because %s\n", gate);
        return;
    }
    isolated = YES;
    installSwizzles();
    test_isolate_host();
}
