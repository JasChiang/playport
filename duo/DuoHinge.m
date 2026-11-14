// SPDX-License-Identifier: GPL-3.0-or-later
//
// DuoHinge: an iPhone Duo (foldable) layout for Playport, injected into the
// official IPA (LC_LOAD_DYLIB) instead of rebuilding Playport.
//
// Playport draws the game aspect-fit over the whole window and pins its touch
// controls to the window's corners. On the Duo's three screen shapes that leaves
// the picture centred under the controls, so DuoHinge moves the game's picture
// (GameSurfaceView's frame) to a rectangle chosen per screen shape, and keeps the
// controls (TouchControlsView) over the whole window:
//   upright (inner 669x951; folded like a laptop or flat): the picture's bottom on
//     the hinge line; the shoulder row (LT/LB/RT/RB/View/Menu) in the strip above
//     it, the sticks and face buttons on the lower half.
//   sideways (inner 951x669, cover 678x466): the picture full width at the top;
//     the sticks and face buttons mostly on the band below it.
// The inner screen turns with the phone (iOS refuses programmatic rotation there);
// the layout follows the window's shape live, during a game.
//
// Targets Playport v0.5.0 (class names and layout read from tag v0.5.0 of this repository).
// Logs go to the system log with the prefix "[duo]".

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <QuartzCore/QuartzCore.h>

static os_log_t duo_log_handle(void) {
    static os_log_t h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = os_log_create("dev.playport.duohinge", "duo"); });
    return h;
}
// Public, so sizes are readable in the device log (no user data is logged).
#define DUO_LOG(fmt, ...) os_log(duo_log_handle(), "[duo] %{public}s", [[NSString stringWithFormat:fmt, ##__VA_ARGS__] UTF8String])

static NSString *const kGameSurfaceClass = @"_TtC8Playport15GameSurfaceView";
static NSString *const kControlsClass = @"_TtC8Playport17TouchControlsView";
static NSString *const kAppDelegateClass = @"_TtC8Playport11AppDelegate";

static NSInteger gHingeStatus = 0;          // UIHingeStatus: 0 unknown, 1 closed, 2 partially open, 3 fully open
static double gHingeAngle = -1;
static __weak UIView *gSurface;              // the GameSurfaceView in a window, if any
static BOOL gApplying;                       // inside our own geometry change
static NSHashTable<UIWindow *> *gHingedWindows;

// Off when the app's defaults hold DuoHingeDisabled = YES (Library/Preferences/<bundle id>.plist).
static BOOL duo_disabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"DuoHingeDisabled"];
}

// Folded far enough to read as a laptop / handheld: in below 145°, out above 160°
// (hysteresis, so holding it near the edge does not flip the layout back and forth).
static BOOL gFolded = NO;
static void duo_update_folded(void) {
    if (gHingeStatus != 2) { gFolded = NO; return; }
    if (gHingeAngle > 0 && gHingeAngle <= 145) gFolded = YES;
    else if (gHingeAngle >= 160) gFolded = NO;
}

/// The inner screen of the Duo (951x669 points either way); the cover is 678x466.
static BOOL duo_is_inner(UIWindow *w) {
    return w && MAX(w.bounds.size.width, w.bounds.size.height) > 800;
}

/// DuoHinge places the game while a game surface is on screen (unless disabled).
static BOOL duo_split(void) {
    return !duo_disabled() && gSurface.window != nil;
}

static void duo_fix_all_margins(void);
static IMP duo_swizzle(Class cls, SEL sel, IMP imp);
static void duo_hook_status_bar(UIWindow *w);
static void duo_hook_root_view(UIWindow *w);
static UIEdgeInsets duo_window_raw_insets(UIWindow *w);

#pragma mark - original IMPs

static IMP sOrigSupportedOrientations;   // -[AppDelegate application:supportedInterfaceOrientationsForWindow:]
static IMP sOrigSurfaceLayout;           // -[GameSurfaceView layoutSubviews]
static IMP sOrigSurfaceDidMoveToWindow;  // -[GameSurfaceView didMoveToWindow]

static void duo_super_setFrame(UIView *v, CGRect r) {
    struct objc_super s = {v, [UIView class]};
    ((void (*)(struct objc_super *, SEL, CGRect))objc_msgSendSuper)(&s, @selector(setFrame:), r);
}

#pragma mark - geometry

/// The game picture's aspect: the swap chain's once it has one, else 16:9.
static CGFloat duo_aspect(UIView *surface) {
    CALayer *l = surface.layer;
    if ([l isKindOfClass:[CAMetalLayer class]]) {
        CGSize d = ((CAMetalLayer *)l).drawableSize;
        if (d.width > 0 && d.height > 0) return d.width / d.height;
    }
    return 16.0 / 9.0;
}

/// Where the game's picture goes, in its superview (which fills the window).
///   Upright, inner screen (folded like a laptop, or flat): the upper half, the picture
///     centred in it; every control on the lower half, below the hinge.
///   Upright, cover screen: the picture full width at the top, every control below it.
///   Sideways: the picture full width at the top, the controls over the whole window
///     (the sticks and face buttons mostly on the band below the picture).
static CGRect duo_game_rect(UIView *surface) {
    CGRect b = surface.superview ? surface.superview.bounds : surface.window.bounds;
    CGFloat W = b.size.width, H = b.size.height, a = duo_aspect(surface);
    CGFloat gh = round(W / a);
    if (H > W) {
        CGFloat top = duo_is_inner(surface.window) ? floor(H / 2.0) : MIN(gh, floor(H / 2.0));
        if (gh <= top) return CGRectMake(0, floor((top - gh) / 2.0), W, gh);
        CGFloat gw = round(top * a);
        return CGRectMake(round((W - gw) / 2.0), 0, gw, top);
    }
    if (gh <= H) return CGRectMake(0, 0, W, gh);
    CGFloat gw = round(H * a);
    return CGRectMake(round((W - gw) / 2.0), 0, gw, H);
}

/// Where the controls go, in the game surface's superview.
static CGRect duo_controls_rect(UIView *surface) {
    CGRect b = surface.superview ? surface.superview.bounds : surface.window.bounds;
    CGFloat W = b.size.width, H = b.size.height;
    if (H > W) {
        CGFloat top = duo_is_inner(surface.window) ? floor(H / 2.0) : CGRectGetMaxY(duo_game_rect(surface));
        return CGRectMake(0, top, W, H - top);
    }
    return b;
}

static void duo_place_surface(UIView *surface) {
    if (!surface || gApplying || !duo_split()) return;
    CGRect want = duo_game_rect(surface);
    if (CGRectEqualToRect(surface.frame, want)) return;
    gApplying = YES;
    duo_super_setFrame(surface, want);
    gApplying = NO;
    [surface setNeedsLayout];
}

#pragma mark - orientation

static void duo_request_orientation(UIWindow *window) {
    if (!window) return;
    [window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
}

static NSString *duo_r(CGRect r) { return NSStringFromCGRect(r); }

/// One line per layer/view that decides where the game's picture lands.
static void duo_dump(NSString *why) {
    UIView *v = gSurface;
    if (!v) return;
    CALayer *l = v.layer;
    NSString *drawable = @"-";
    if ([l isKindOfClass:[CAMetalLayer class]]) drawable = NSStringFromCGSize(((CAMetalLayer *)l).drawableSize);
    DUO_LOG(@"dump(%@) split=%d window=%@ safe=%@", why, duo_split(), duo_r(v.window.bounds), NSStringFromUIEdgeInsets(v.window.safeAreaInsets));
    DUO_LOG(@"  surface frame=%@ bounds=%@ transform=%@ scale=%.2f", duo_r(v.frame), duo_r(v.bounds),
            NSStringFromCGAffineTransform(v.transform), v.contentScaleFactor);
    DUO_LOG(@"  layer %@ gravity=%@ drawable=%@ contentsScale=%.2f contentsRect=%@", NSStringFromClass([l class]),
            l.contentsGravity, drawable, l.contentsScale, duo_r(l.contentsRect));
    for (CALayer *s in l.sublayers) DUO_LOG(@"  sublayer %@ frame=%@ hidden=%d", NSStringFromClass([s class]), duo_r(s.frame), s.hidden);
    for (UIView *s in v.subviews) DUO_LOG(@"  subview %@ frame=%@", NSStringFromClass([s class]), duo_r(s.frame));
    int depth = 0;
    for (UIView *p = v.superview; p && depth < 6; p = p.superview, depth++)
        DUO_LOG(@"  super[%d] %@ frame=%@ bounds=%@", depth, NSStringFromClass([p class]), duo_r(p.frame), duo_r(p.bounds));
}

static void duo_apply(NSString *why) {
    UIView *surface = gSurface;
    UIWindow *window = surface.window;
    DUO_LOG(@"apply (%@): hinge=%ld angle=%.0f surface=%@ split=%d window=%@",
            why, (long)gHingeStatus, gHingeAngle, surface ? @"yes" : @"no", duo_split(),
            window ? NSStringFromCGRect(window.bounds) : @"-");
    if (!window) return;
    duo_request_orientation(window);
    if (duo_split()) {
        duo_place_surface(surface);
    } else {
        // Back to Playport's own layout: let SwiftUI size the view again.
        [surface.superview setNeedsLayout];
        [surface.superview layoutIfNeeded];
    }
    [surface setNeedsLayout];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ duo_dump(why); });
}

#pragma mark - swizzled methods

static UIInterfaceOrientationMask duo_supportedOrientations(id self, SEL _cmd, UIApplication *app, UIWindow *window) {
    UIInterfaceOrientationMask original =
        ((UIInterfaceOrientationMask (*)(id, SEL, UIApplication *, UIWindow *))sOrigSupportedOrientations)(self, _cmd, app, window);
    // Inner screen: let it turn with the phone (upright = split, sideways = full screen).
    // Cover screen: Playport's own landscape.
    if (!duo_disabled() && duo_is_inner(window)) return UIInterfaceOrientationMaskAllButUpsideDown;
    return original;
}

static void duo_surface_didMoveToWindow(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))sOrigSurfaceDidMoveToWindow)(self, _cmd);   // asks for landscape
    if (self.window) {
        gSurface = self;
        duo_fix_all_margins();
        DUO_LOG(@"game surface in window %@ frame=%@", NSStringFromCGRect(self.window.bounds), NSStringFromCGRect(self.frame));
        if (duo_split()) duo_apply(@"surface shown");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ duo_dump(@"surface shown"); });
    } else if (gSurface == self) {
        gSurface = nil;
        duo_fix_all_margins();
        DUO_LOG(@"game surface left its window");
        dispatch_async(dispatch_get_main_queue(), ^{ duo_apply(@"surface gone"); });
    }
}

static void duo_surface_setFrame(UIView *self, SEL _cmd, CGRect r) {
    duo_super_setFrame(self, r);
    duo_place_surface(self);
}

static void duo_surface_setBounds(UIView *self, SEL _cmd, CGRect r) {
    struct objc_super s = {self, [UIView class]};
    ((void (*)(struct objc_super *, SEL, CGRect))objc_msgSendSuper)(&s, _cmd, r);
    duo_place_surface(self);
}

static void duo_surface_setCenter(UIView *self, SEL _cmd, CGPoint c) {
    struct objc_super s = {self, [UIView class]};
    ((void (*)(struct objc_super *, SEL, CGPoint))objc_msgSendSuper)(&s, _cmd, c);
    duo_place_surface(self);
}

static UIView *duo_controls(UIView *surface) {
    Class cls = NSClassFromString(kControlsClass);
    for (UIView *v in surface.subviews) if ([v isKindOfClass:cls]) return v;
    return nil;
}

static void duo_surface_layoutSubviews(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))sOrigSurfaceLayout)(self, _cmd);   // every overlay = bounds
    if (!duo_split() || gSurface != self) return;
    duo_place_surface(self);   // the swap chain's aspect may have changed
    UIView *controls = duo_controls(self);
    if (!controls || !self.superview) return;
    CGRect whole = [self convertRect:duo_controls_rect(self) fromView:self.superview];
    if (!CGRectEqualToRect(controls.frame, whole)) {
        controls.frame = whole;
        DUO_LOG(@"layout: game %@, controls %@ (window %@)", NSStringFromCGRect(self.frame),
                NSStringFromCGRect(whole), NSStringFromCGRect(self.window.bounds));
    }
}

/// Lets hit-testing reach the controls below the view's own bounds.
static BOOL duo_surface_pointInside(UIView *self, SEL _cmd, CGPoint p, UIEvent *event) {
    if (duo_split()) {
        UIView *controls = duo_controls(self);
        if (controls && CGRectContainsPoint(controls.frame, p)) return YES;
    }
    struct objc_super s = {self, [UIView class]};
    return ((BOOL (*)(struct objc_super *, SEL, CGPoint, UIEvent *))objc_msgSendSuper)(&s, _cmd, p, event);
}

/// Touch controls: the same side margin on both sides. The cover screen's camera puts an
/// 84-point inset on one side only, which pushed every control toward the other edge.
static CGFloat duo_inset_both(UIEdgeInsets i) { return MAX(i.left, i.right); }
static IMP sOrigControlsSafeArea;
static UIEdgeInsets duo_controls_safeAreaInsets(UIView *self, SEL _cmd) {
    UIEdgeInsets i = ((UIEdgeInsets (*)(id, SEL))sOrigControlsSafeArea)(self, _cmd);
    if (duo_disabled()) return i;
    UIWindow *win = self.window;
    if (win && (win.bounds.size.height > win.bounds.size.width || duo_is_inner(win))) {
        // Upright (the island is at the top) and the inner screen (no island; sideways its
        // status bar is hidden over a game): a side inset here is left over from the other
        // orientation, not something on the screen.
        i.left = i.right = 0;
        return i;
    }
    UIEdgeInsets w = win ? win.safeAreaInsets : UIEdgeInsetsZero;
    CGFloat side = MAX(duo_inset_both(i), duo_inset_both(w));
    i.left = i.right = side;
    return i;
}

/// Playport's pages take their side margins from the safe area. The Duo's inner screen has
/// none on one side (sideways the status bar sits on the other), so pages ran into the edge.
/// Give every side at least kMinSideMargin points through the root view controller.
static const CGFloat kMinSideMargin = 16;
/// Playport's own window: its root is SwiftUI's hosting controller (not the keyboard's or
/// another system window, whose views are not SwiftUI's hosting view).
static BOOL duo_is_app_window(UIWindow *w) {
    UIViewController *root = w.rootViewController;
    return root && [NSStringFromClass(object_getClass(root)) containsString:@"UIHostingController"];
}

static void duo_fix_margins(UIWindow *w) {
    UIViewController *root = w.rootViewController;
    if (!root || duo_disabled() || !duo_is_app_window(w)) return;
    duo_hook_status_bar(w);
    duo_hook_root_view(w);
    [root setNeedsStatusBarAppearanceUpdate];
    UIEdgeInsets sys = duo_window_raw_insets(w), add = root.additionalSafeAreaInsets;
    // window.safeAreaInsets is the system's own; additionalSafeAreaInsets only reaches subviews.
    UIEdgeInsets want = UIEdgeInsetsMake(0, MAX(0, kMinSideMargin - sys.left), 0, MAX(0, kMinSideMargin - sys.right));
    CGSize ws = w.bounds.size;
    if (duo_is_inner(w) && ws.width > ws.height) {
        // Sideways on the inner screen the status bar is hidden (duo_statusBarHidden), but the
        // window can keep reporting its 84-point column: cancel it, same margin both sides.
        want.left = kMinSideMargin - sys.left;
        want.right = kMinSideMargin - sys.right;
    }
    // Folded like a laptop, upright, with no game: Playport's pages (designed for a landscape
    // phone) go on the upper screen only, a 669x475 landscape-like page; the lower one is the
    // base, holding only the footer of button hints (it ignores the bottom safe area).
    CGSize sz = w.bounds.size;
    if (gFolded && sz.height > sz.width && gSurface.window != w)
        want.bottom = MAX(0, sz.height - floor(sz.height / 2.0) - sys.bottom);
    if (UIEdgeInsetsEqualToEdgeInsets(add, want)) return;
    root.additionalSafeAreaInsets = want;
    DUO_LOG(@"page insets: system=%@ added=%@", NSStringFromUIEdgeInsets(sys), NSStringFromUIEdgeInsets(want));
}
static void duo_fix_all_margins(void) {
    for (UIWindow *w in gHingedWindows) duo_fix_margins(w);
}

/// Sideways on the inner screen the status bar takes an 84-point column on one side, so
/// Playport's pages sat off-centre (16 points on one side, 84 on the other). Hidden there,
/// both sides get the same margin. Playport hides it itself over a game.
static IMP sOrigStatusBarHidden;
static Class sStatusBarClass;
static BOOL duo_statusBarHidden(UIViewController *self, SEL _cmd) {
    BOOL original = ((BOOL (*)(id, SEL))sOrigStatusBarHidden)(self, _cmd);
    UIWindow *w = self.viewIfLoaded.window;
    if (duo_disabled() || !w || !duo_is_inner(w)) return original;
    return original || w.bounds.size.width > w.bounds.size.height;
}
static void duo_hook_status_bar(UIWindow *w) {
    UIViewController *root = w.rootViewController;
    if (!root || sStatusBarClass) return;
    sStatusBarClass = object_getClass(root);
    sOrigStatusBarHidden = duo_swizzle(sStatusBarClass, @selector(prefersStatusBarHidden), (IMP)duo_statusBarHidden);
    DUO_LOG(@"status bar hook on %@", NSStringFromClass(sStatusBarClass));
}

/// Sideways on the inner screen (951x669) Playport's pages, designed for a landscape phone
/// (about 852x393), leave much of the height empty. With no game on screen the page is laid
/// out for a smaller canvas (the window divided by kPageScale) and drawn kPageScale times
/// larger, so it fills the screen exactly: edge controls stay on the edges, nothing spills.
static const CGFloat kPageScale = 1.2;
static Class sRootViewClass;
// _UIHostingView's own setFrame:/setBounds:/setCenter: (they tell SwiftUI the new size).
static IMP sOrigRootSetFrame, sOrigRootSetBounds, sOrigRootSetCenter;
static CGFloat duo_page_scale(UIWindow *w) {
    if (duo_disabled() || !w || !duo_is_inner(w)) return 1;
    if (gSurface.window) return 1;   // a game: Playport's own geometry (and DuoHinge's game layout)
    return w.bounds.size.width > w.bounds.size.height ? kPageScale : 1;
}
static void duo_place_root(UIView *v) {
    UIWindow *w = v.window;
    if (!v || !w || gApplying || v != w.rootViewController.viewIfLoaded || object_getClass(v) != sRootViewClass) return;
    CGFloat sc = duo_page_scale(w);
    CGSize W = w.bounds.size;
    CGRect bounds = CGRectMake(0, 0, floor(W.width / sc), floor(W.height / sc));
    CGPoint center = CGPointMake(W.width / 2.0, W.height / 2.0);
    CGAffineTransform t = sc == 1 ? CGAffineTransformIdentity : CGAffineTransformMakeScale(W.width / bounds.size.width,
                                                                                            W.height / bounds.size.height);
    if (CGRectEqualToRect(v.bounds, bounds) && CGPointEqualToPoint(v.center, center) && CGAffineTransformEqualToTransform(v.transform, t)) return;
    gApplying = YES;
    v.transform = t;
    ((void (*)(id, SEL, CGRect))sOrigRootSetBounds)(v, @selector(setBounds:), bounds);
    ((void (*)(id, SEL, CGPoint))sOrigRootSetCenter)(v, @selector(setCenter:), center);
    gApplying = NO;
    [v setNeedsLayout];
    DUO_LOG(@"page scale %.2f: canvas %@ in window %@", sc, NSStringFromCGSize(bounds.size), NSStringFromCGSize(W));
}
static void duo_root_setFrame(UIView *self, SEL _cmd, CGRect r) {
    if (!gApplying && !CGAffineTransformIsIdentity(self.transform)) { duo_place_root(self); return; }
    ((void (*)(id, SEL, CGRect))sOrigRootSetFrame)(self, _cmd, r);
    duo_place_root(self);
}
static void duo_root_setBounds(UIView *self, SEL _cmd, CGRect r) {
    ((void (*)(id, SEL, CGRect))sOrigRootSetBounds)(self, _cmd, r);
    duo_place_root(self);
}
static void duo_root_setCenter(UIView *self, SEL _cmd, CGPoint c) {
    ((void (*)(id, SEL, CGPoint))sOrigRootSetCenter)(self, _cmd, c);
    duo_place_root(self);
}
static void duo_hook_root_view(UIWindow *w) {
    UIView *v = w.rootViewController.viewIfLoaded;
    if (!v) return;
    if (!sRootViewClass) {
        sRootViewClass = object_getClass(v);
        sOrigRootSetFrame = duo_swizzle(sRootViewClass, @selector(setFrame:), (IMP)duo_root_setFrame);
        sOrigRootSetBounds = duo_swizzle(sRootViewClass, @selector(setBounds:), (IMP)duo_root_setBounds);
        sOrigRootSetCenter = duo_swizzle(sRootViewClass, @selector(setCenter:), (IMP)duo_root_setCenter);
        DUO_LOG(@"page scale hook on %@", NSStringFromClass(sRootViewClass));
    }
    duo_place_root(v);
}

/// The window's insets as Playport's controls read them (gameSafeInsets takes the larger of the
/// view's and the window's): the same left-over side insets dropped, on Playport's window only.
static IMP sOrigWindowSafeArea;
static UIEdgeInsets duo_window_raw_insets(UIWindow *w) {
    return ((UIEdgeInsets (*)(id, SEL))sOrigWindowSafeArea)(w, @selector(safeAreaInsets));
}
static UIEdgeInsets duo_window_safeAreaInsets(UIWindow *self, SEL _cmd) {
    UIEdgeInsets i = duo_window_raw_insets(self);
    if (duo_disabled() || !sStatusBarClass || object_getClass(self.rootViewController) != sStatusBarClass) return i;
    CGSize sz = self.bounds.size;
    if (sz.height > sz.width || duo_is_inner(self)) i.left = i.right = 0;
    return i;
}

static IMP sOrigWindowSafeAreaChanged;
static void duo_window_safeAreaInsetsDidChange(UIWindow *self, SEL _cmd) {
    ((void (*)(id, SEL))sOrigWindowSafeAreaChanged)(self, _cmd);
    duo_fix_margins(self);
}

#pragma mark - hinge

static void duo_hinge_update(NSInteger status, double angle) {
    BOOL angleChanged = fabs(angle - gHingeAngle) >= 10;
    BOOL wasFolded = gFolded;
    NSInteger was = gHingeStatus;
    gHingeStatus = status;
    gHingeAngle = angle;
    duo_update_folded();
    if (status != was || angleChanged) DUO_LOG(@"hinge status=%ld angle=%.0f folded=%d", (long)status, angle, gFolded);
    if (gFolded != wasFolded || status != was) { duo_fix_all_margins(); duo_apply(@"hinge"); }
}

static void duo_attach_hinge(UIWindow *window) {
    if (!window || [gHingedWindows containsObject:window]) return;
    if (@available(iOS 27.1, *)) {
        Class cls = NSClassFromString(@"UIHingeInteraction");
        if (!cls) { DUO_LOG(@"UIHingeInteraction not available"); return; }
        UIHingeInteraction *hinge = [[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *i, UIHingeInteractionUpdate *u) {
            UIHinge *h = u.hinge;
            duo_hinge_update(h ? (NSInteger)h.status : 0, h ? h.angle * 180.0 / M_PI : -1);
        }];
        duo_fix_margins(window);
        [window addInteraction:hinge];
        [gHingedWindows addObject:window];
        DUO_LOG(@"hinge interaction on window %@", NSStringFromCGRect(window.bounds));
    } else {
        DUO_LOG(@"iOS below 27.1: no hinge");
    }
}

#pragma mark - install

static IMP duo_swizzle(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    // Add on the class itself when it only inherits the method, so the original
    // resolves to the superclass implementation rather than being replaced for UIView.
    if (class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) return method_getImplementation(m);
    return method_setImplementation(m, imp);
}

__attribute__((constructor)) static void duo_init(void) {
    gHingedWindows = [NSHashTable weakObjectsHashTable];
    Class surface = NSClassFromString(kGameSurfaceClass);
    Class delegate = NSClassFromString(kAppDelegateClass);
    if (!surface || !delegate || !NSClassFromString(kControlsClass)) {
        DUO_LOG(@"Playport classes not found (surface=%@ delegate=%@): not installing", surface, delegate);
        return;
    }
    sOrigSupportedOrientations = duo_swizzle(delegate, @selector(application:supportedInterfaceOrientationsForWindow:),
                                             (IMP)duo_supportedOrientations);
    sOrigSurfaceLayout = duo_swizzle(surface, @selector(layoutSubviews), (IMP)duo_surface_layoutSubviews);
    sOrigSurfaceDidMoveToWindow = duo_swizzle(surface, @selector(didMoveToWindow), (IMP)duo_surface_didMoveToWindow);
    duo_swizzle(surface, @selector(setFrame:), (IMP)duo_surface_setFrame);
    duo_swizzle(surface, @selector(setBounds:), (IMP)duo_surface_setBounds);
    duo_swizzle(surface, @selector(setCenter:), (IMP)duo_surface_setCenter);
    duo_swizzle(surface, @selector(pointInside:withEvent:), (IMP)duo_surface_pointInside);
    sOrigWindowSafeArea = duo_swizzle([UIWindow class], @selector(safeAreaInsets), (IMP)duo_window_safeAreaInsets);
    sOrigWindowSafeAreaChanged = duo_swizzle([UIWindow class], @selector(safeAreaInsetsDidChange),
                                             (IMP)duo_window_safeAreaInsetsDidChange);
    sOrigControlsSafeArea = duo_swizzle(NSClassFromString(kControlsClass), @selector(safeAreaInsets),
                                        (IMP)duo_controls_safeAreaInsets);
    DUO_LOG(@"installed (orientations=%d layout=%d didMove=%d)%@",
            sOrigSupportedOrientations != NULL, sOrigSurfaceLayout != NULL, sOrigSurfaceDidMoveToWindow != NULL,
            duo_disabled() ? @" — disabled by DuoHingeDisabled" : @"");

    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) { duo_attach_hinge(n.object); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) { duo_attach_hinge(n.object); }];
}
