//
//  Tweak.xm
//  TrollRecorderBrowserPicker
//
//  Let the user choose how TrollRecorder's login (ASWebAuthenticationSession)
//  opens — specifically to use an *isolated* Safari session so they can sign in
//  with a different account without disturbing their main Safari login.
//
//  IMPORTANT — why only Safari works here:
//  TrollRecorder's auth rides on the Havoc/Sileo payment service, whose callback
//  scheme is `sileo://`. That scheme is *owned by the Sileo app*, not by
//  TrollRecorder. A real third-party browser (Alook/Chrome/Quark) opens the login
//  page, the server redirects to `sileo://…`, and iOS hands that scheme to Sileo —
//  so the callback can never return to TrollRecorder. This is an iOS URL-scheme
//  limitation and cannot be worked around. Therefore the ONLY viable choices are
//  the two in-process Safari modes, which intercept `sileo://` internally and
//  deliver it straight back to TrollRecorder.
//
//  Design: Safari modes are 100% native pass-throughs (no state, no swizzle),
//  so they behave exactly like stock TrollRecorder. The tweak only engages its
//  machinery in "每次询问" (ask) mode, where it shows a picker offering the two
//  Safari options.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ===== Version =====
#define TRP_VERSION @"1.0.3"

// ===== Preferences =====
#define PREFS_PATH @"/var/mobile/Library/Preferences/com.mosheng.trappbrowserpicker.plist"
#define kEnabled   @"enabled"
#define kMode      @"browserMode"

// Browser modes
#define TRP_DISABLED           0
#define TRP_SAFARI_DEFAULT     1
#define TRP_SAFARI_EPHEMERAL   2
#define TRP_ASK                6

// ASWebAuthenticationSessionError.canceledLogin = 10
#define TRP_CANCEL_CODE 10
#define TRP_ERROR_DOMAIN @"ASWebAuthenticationSessionErrorDomain"

// ===== Class declaration for compiler =====
@interface ASWebAuthenticationSession : NSObject
- (instancetype)initWithURL:(NSURL *)URL
        callbackURLScheme:(NSString *)callbackURLScheme
       completionHandler:(void (^)(NSURL *, NSError *))completionHandler;
- (BOOL)start;
@property (nonatomic) BOOL prefersEphemeralWebBrowserSession;
@end

// ===== Pending auth state (only used in "每次询问" mode) =====
static NSURL   *s_pendingURL    = nil;
static void (^s_pendingHandler)(NSURL *, NSError *) = nil;
static ASWebAuthenticationSession *s_pendingSession = nil;
static BOOL    s_hasPending     = NO;

// Bypass flag: lets us re-start the ORIGINAL session from the picker without
// re-triggering our own start hook.
static BOOL s_bypassHook = NO;

// ===== Auto-cancel observer handle =====
static id s_activeObserver = nil;

// ===== Helpers =====

static BOOL trpEnabled(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSNumber *en = d[kEnabled];
    return en ? en.boolValue : NO;   // default OFF — zero interference until enabled
}

static NSInteger trpMode(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSNumber *m = d[kMode];
    return m ? m.integerValue : TRP_DISABLED;
}

static void cleanupPending(void) {
    s_pendingURL    = nil;
    s_pendingHandler = nil;
    s_pendingSession = nil;
    s_hasPending    = NO;
    if (s_activeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:s_activeObserver];
        s_activeObserver = nil;
    }
}

static void cancelPendingAuth(void) {
    if (!s_hasPending) return;
    void (^handler)(NSURL *, NSError *) = s_pendingHandler;
    cleanupPending();
    NSError *err = [NSError errorWithDomain:TRP_ERROR_DOMAIN
                                        code:TRP_CANCEL_CODE
                                    userInfo:nil];
    handler(nil, err);
}

// Get the active window (iOS 13+ UIScene compatible)
static UIWindow *trpActiveWindow(void) {
    for (UIScene *scene in [UIApplication.sharedApplication connectedScenes]) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) return w;
                }
                if (ws.windows.count > 0) return ws.windows.firstObject;
            }
        }
    }
    return nil;
}

// Present a view controller safely
static void trpPresent(UIAlertController *alert) {
    UIWindow *win = trpActiveWindow();
    if (!win) {
        win = [[UIWindow alloc] initWithFrame:[UIScreen.mainScreen bounds]];
        win.windowLevel = UIWindowLevelAlert;
        [win makeKeyAndVisible];
    }
    UIViewController *vc = win.rootViewController;
    if (!vc) {
        vc = [[UIViewController alloc] init];
        win.rootViewController = vc;
    }
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    [vc presentViewController:alert animated:YES completion:nil];
}

// Start TrollRecorder's ORIGINAL session with the chosen ephemeral flag.
// Reusing the original session object (which already has its
// presentationContextProvider configured by the app) avoids the
// presentationContextInvalid (error 2) that a freshly allocated session would hit.
static void trpStartNative(BOOL ephemeral) {
    if (s_hasPending && s_pendingSession && s_pendingHandler) {
        s_bypassHook = YES;
        s_pendingSession.prefersEphemeralWebBrowserSession = ephemeral;
        [s_pendingSession start];
        s_bypassHook = NO;
        cleanupPending();
    }
}

// Show browser picker action sheet (only Safari options are viable — see header)
static void showBrowserPicker(NSURL *authURL) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"选择登录方式"
                             message:@"巨魔录音机的登录回调是 sileo://（属于 Sileo App）。第三方浏览器打开后无法把结果送回巨魔录音机，因此只能用 Safari。\n\n· Safari（默认）：共享 Safari Cookie\n· Safari（独立会话）：隔离 Cookie，可用于切换账号"
                      preferredStyle:UIAlertControllerStyleActionSheet];

        [alert addAction:[UIAlertAction actionWithTitle:@"Safari (默认)"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
            trpStartNative(NO);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Safari (独立会话)"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
            trpStartNative(YES);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                   style:UIAlertActionStyleCancel
                                                 handler:^(UIAlertAction *a) {
            cancelPendingAuth();
        }]];

        trpPresent(alert);
    });
}

// Setup auto-cancel: if the user returns to the app without completing auth,
// cancel after a grace period so we don't leave a dangling pending session.
static void setupAutoCancel(void) {
    if (s_activeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:s_activeObserver];
        s_activeObserver = nil;
    }
    s_activeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (s_hasPending) cancelPendingAuth();
        });
    }];
}

// ===== Hooks =====

%group ASWebAuthHooks

%hook ASWebAuthenticationSession

- (instancetype)initWithURL:(NSURL *)url
        callbackURLScheme:(NSString *)scheme
       completionHandler:(void (^)(NSURL *, NSError *))handler {
    ASWebAuthenticationSession *ret = %orig;

    // Only capture state when we will actually intercept (ask mode). For every
    // other mode we leave the session completely untouched → native behavior.
    if (!s_bypassHook && url && scheme && trpEnabled() && trpMode() == TRP_ASK) {
        s_pendingURL     = [url copy];
        s_pendingHandler = [handler copy];
        s_pendingSession = ret;
        s_hasPending     = YES;
    }

    return ret;
}

- (BOOL)start {
    // Bypass: internal re-start from the picker (uses the original session).
    if (s_bypassHook) {
        return %orig;
    }

    // Disabled or plugin off → fully native.
    if (!s_hasPending || !trpEnabled()) {
        return %orig;
    }

    NSInteger mode = trpMode();

    switch (mode) {
        case TRP_DISABLED:
        case TRP_SAFARI_DEFAULT:
            // Pure native — same as stock TrollRecorder.
            return %orig;

        case TRP_SAFARI_EPHEMERAL:
            // Native, but with an isolated (ephemeral) cookie jar. This is what
            // lets the user sign in with a different account without disturbing
            // their main Safari login.
            self.prefersEphemeralWebBrowserSession = YES;
            return %orig;

        case TRP_ASK:
        default:
            // Show picker; the chosen Safari option starts the original session.
            showBrowserPicker(s_pendingURL);
            setupAutoCancel();
            return YES;  // Pretend session started
    }
}

%end // %hook ASWebAuthenticationSession

%end // %group ASWebAuthHooks

// ===== Constructor =====
%ctor {
    %init(ASWebAuthHooks);
    NSLog(@"[TrollRecorderBrowserPicker] v%@ loaded (enabled=%d mode=%ld)",
          TRP_VERSION, trpEnabled(), (long)trpMode());
}
