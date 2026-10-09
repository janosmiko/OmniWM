// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

BOOL OmniWMTestHostIsIsolated(void);

// Under isolation makeKeyWindow is a no-op, so this reports the window the code asked to make key.
BOOL OmniWMTestWindowIsKey(NSWindow *window);

NS_ASSUME_NONNULL_END
