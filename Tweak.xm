//
//  Tweak.xm
//  TrollRecorderBrowserPicker
//
//  Intercept TrollRecorder's ASWebAuthenticationSession login flow
//  (the "只能用 Safari 登录" prompt) and redirect it to a user-selected
//  third-party browser (Alook / Chrome / Quark / Safari / Safari-ephemeral).
//
//  The callback URL scheme is captured at runtime from the session, so this
//  works regardless of what scheme TrollRecorder actually registers — we never
//  hardcode it.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ===== Version =====
#define TRP_VERSION @"1.0.1"

// ===== Preferences =====
#define PREFS_PATH @"/var/mobile/Library/Preferences/com.mosheng.trappbrowserpicker.plist"
#define kEnabled   @"enabled"
#define kMode      @"browserMode"

// Browser modes
#define TRP_DISABLED           0
#define TRP_SAFARI_DEFAULT     1
#define TRP_SAFARI_EPHEMERAL   2
#define TRP_ALOOK              3
#define TRP_CHROME             4
#define TRP_QUARK              5
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
@property (nonatomic, weak) id presentationContextProvider;
@end

// ===== Pending auth state =====
static NSURL   *s_pendingURL    = nil;
static NSString *s_pendingScheme = nil;
static void (^s_pendingHandler)(NSURL *, NSError *) = nil;
static ASWebAuthenticationSession *s_pendingSession = nil;
static BOOL    s_hasPending     = NO;

// ===== Auto-cancel observer =====
static id s_activeObserver = nil;

// ===== Delegate swizzle =====
static BOOL s_delegateSwizzled = NO;
static IMP  s_orig_openURL     = NULL;

// ===== Bypass flag (for creating new session internally) =====
static BOOL s_bypassHook = NO;

// ===== External browser flow flag =====
// YES when we redirected to an external browser or showed the picker.
// In that case the ASWebAuthenticationSession itself is NOT active, so the
// AppDelegate swizzle must manually deliver the callback to the stored
// completion handler. For native Safari modes we call %orig and the session
// handles the callback itself; our swizzle must NOT call the handler again, or
// the session throws WebAuthenticationSession error 2.
static BOOL s_externalFlow = NO;

// App's own registered URL scheme (read from TrollRecorder's Info.plist at load).
// Used so external-browser callbacks can be redirected back INTO TrollRecorder
// instead of to the scheme the auth server expects (e.g. sileo://, which would
// open Sileo). nil if the app registers no scheme.
static NSString *g_appScheme = nil;
// The original scheme TrollRecorder passed to ASWebAuthenticationSession (e.g. sileo).
// Its completion handler expects a callback URL carrying this scheme, so we rewrite
// the app-scheme callback back to this one before delivering.
static NSString *s_origScheme = nil;

// ===== Helpers =====

static BOOL trpEnabled(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSNumber *en = d[kEnabled];
    return en ? en.boolValue : YES;
}

static NSInteger trpMode(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSNumber *m = d[kMode];
    return m ? m.integerValue : TRP_ASK;
}

static void cleanupPending(void) {
    s_pendingURL    = nil;
    s_pendingScheme = nil;
    s_pendingHandler = nil;
    s_pendingSession = nil;
    s_hasPending    = NO;
    s_externalFlow  = NO;
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

// Open auth URL in a third-party browser
static void openInBrowser(NSURL *authURL, NSInteger mode) {
    NSString *urlStr = authURL.absoluteString;
    NSURL *openURL = nil;

    switch (mode) {
        case TRP_ALOOK:
            // Alook: Alook://<fullurl>
            openURL = [NSURL URLWithString:[NSString stringWithFormat:@"Alook://%@", urlStr]];
            break;
        case TRP_CHROME: {
            // Chrome: replace https:// -> googlechromes://, http:// -> googlechrome://
            NSString *chrome = [urlStr stringByReplacingOccurrencesOfString:@"https://"
                                                                  withString:@"googlechromes://"];
            chrome = [chrome stringByReplacingOccurrencesOfString:@"http://"
                                                       withString:@"googlechrome://"];
            openURL = [NSURL URLWithString:chrome];
            break;
        }
        case TRP_QUARK: {
            // Quark: quark://web?target=<percent-encoded>
            NSString *encoded = [urlStr stringByAddingPercentEncodingWithAllowedCharacters:
                                 [NSCharacterSet URLQueryAllowedCharacterSet]];
            openURL = [NSURL URLWithString:[NSString stringWithFormat:@"quark://web?target=%@", encoded]];
            break;
        }
    }

    if (openURL) {
        // Use openURL:options:completionHandler: (bypasses canOpenURL restriction)
        [[UIApplication sharedApplication] openURL:openURL
                                           options:@{}
                                 completionHandler:nil];
    }
}

// Read TrollRecorder's own registered URL scheme from its Info.plist.
// The tweak is injected into TrollRecorder, so [NSBundle mainBundle] is TrollRecorder.
static void trpLoadAppScheme(void) {
    NSBundle *b = [NSBundle mainBundle];
    NSArray *types = b.infoDictionary[@"CFBundleURLTypes"];
    for (NSDictionary *t in types) {
        NSArray *schemes = t[@"CFBundleURLSchemes"];
        for (NSString *s in schemes) {
            if (s.length) { g_appScheme = [s copy]; return; }
        }
    }
}

// Rewrite every occurrence of `<from>://` (and its percent-encoded form) in a URL
// string to `<to>://`. Used to retarget the auth callback from the server-expected
// scheme (sileo://) to TrollRecorder's own scheme so external browsers hand the
// callback back to TrollRecorder.
static NSURL *trpRewriteScheme(NSURL *url, NSString *from, NSString *to) {
    if (!from.length || !to.length) return url;
    NSString *s = url.absoluteString;
    NSString *fromDec = [NSString stringWithFormat:@"%@://", from];
    NSString *fromEnc = [NSString stringWithFormat:@"%@%%3A%%2F%%2F", from];
    NSString *toDec = [NSString stringWithFormat:@"%@://", to];
    NSString *toEnc = [NSString stringWithFormat:@"%@%%3A%%2F%%2F", to];
    s = [s stringByReplacingOccurrencesOfString:fromDec withString:toDec
                                      options:NSCaseInsensitiveSearch range:NSMakeRange(0, s.length)];
    s = [s stringByReplacingOccurrencesOfString:fromEnc withString:toEnc
                                      options:NSCaseInsensitiveSearch range:NSMakeRange(0, s.length)];
    return [NSURL URLWithString:s] ?: url;
}

// Open the auth URL in a third-party browser, retargeting the callback to
// TrollRecorder's own scheme (when available) so the callback returns here.
static void openExternal(NSURL *authURL, NSInteger mode) {
    if (g_appScheme && g_appScheme.length && s_origScheme && s_origScheme.length) {
        s_pendingScheme = [g_appScheme copy];
        NSURL *modified = trpRewriteScheme(authURL, s_origScheme, g_appScheme);
        openInBrowser(modified, mode);
    } else {
        openInBrowser(authURL, mode);
    }
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
        // Fallback: create a temporary window
        win = [[UIWindow alloc] initWithFrame:[UIScreen.mainScreen bounds]];
        win.windowLevel = UIWindowLevelAlert;
        [win makeKeyAndVisible];
    }
    UIViewController *vc = win.rootViewController;
    if (!vc) {
        // No root VC — create a transparent host
        vc = [[UIViewController alloc] init];
        win.rootViewController = vc;
    }
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    [vc presentViewController:alert animated:YES completion:nil];
}

// Show browser picker action sheet
static void showBrowserPicker(NSURL *authURL) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"选择浏览器"
                             message:@"选择用于登录的浏览器"
                      preferredStyle:UIAlertControllerStyleActionSheet];

        [alert addAction:[UIAlertAction actionWithTitle:@"Alook"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
            openExternal(authURL, TRP_ALOOK);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Chrome"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
            openExternal(authURL, TRP_CHROME);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"夸克"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
            openExternal(authURL, TRP_QUARK);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Safari (默认)"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
            // Reuse TrollRecorder's ORIGINAL session object — it already has its
            // presentationContextProvider configured by the app, so starting it
            // natively gives the normal shared-cookie Safari login (same as
            // stock). A freshly allocated session would lack the provider and
            // throw WebAuthenticationSession error 2.
            if (s_hasPending && s_pendingSession && s_pendingHandler) {
                s_bypassHook = YES;
                s_pendingSession.prefersEphemeralWebBrowserSession = NO;
                [s_pendingSession start];
                s_bypassHook = NO;
                cleanupPending();
            }
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Safari (独立会话)"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
            // Same as above but with an ephemeral (cookie-isolated) session.
            // Reusing the original session avoids the presentationContextInvalid
            // error 2 that a brand-new session would hit.
            if (s_hasPending && s_pendingSession && s_pendingHandler) {
                s_bypassHook = YES;
                s_pendingSession.prefersEphemeralWebBrowserSession = YES;
                [s_pendingSession start];
                s_bypassHook = NO;
                cleanupPending();
            }
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                   style:UIAlertActionStyleCancel
                                                 handler:^(UIAlertAction *a) {
            cancelPendingAuth();
        }]];

        trpPresent(alert);
    });
}

// Setup auto-cancel: if user returns to the app without completing auth
static void setupAutoCancel(void) {
    __block id observer = nil;
    observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        // Delay 1.2s to allow callback URL processing
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (s_hasPending) {
                cancelPendingAuth();
            }
        });
    }];
    s_activeObserver = observer;
}

// ===== Swizzled application:openURL:options: =====
static BOOL swizzled_openURL_impl(id self, SEL _cmd,
                                  UIApplication *application,
                                  NSURL *url,
                                  NSDictionary *options) {
    // Only manually deliver the callback when we redirected to an external
    // browser or showed the picker. Native Safari/ASWebAuthenticationSession
    // modes handle the callback internally; calling the handler again would
    // produce WebAuthenticationSession error 2.
    //
    // The scheme is matched against the one captured from the session (NOT
    // hardcoded), so this works for whatever scheme TrollRecorder registers.
    if (s_hasPending && s_externalFlow && url.scheme && s_pendingScheme &&
        [url.scheme caseInsensitiveCompare:s_pendingScheme] == NSOrderedSame) {
        // Capture the handler before cleanup
        void (^handler)(NSURL *, NSError *) = s_pendingHandler;

        // The callback arrived via TrollRecorder's own scheme (g_appScheme). The
        // completion handler expects the ORIGINAL scheme TrollRecorder passed to
        // ASWebAuthenticationSession (e.g. sileo://), so rewrite the scheme back
        // before delivering — the rest of the URL (token, etc.) is untouched.
        NSURL *deliverURL = url;
        if (s_origScheme && s_origScheme.length &&
            [url.scheme caseInsensitiveCompare:s_origScheme] != NSOrderedSame) {
            NSString *s = url.absoluteString;
            NSString *cur = [NSString stringWithFormat:@"%@://", url.scheme];
            NSString *orig = [NSString stringWithFormat:@"%@://", s_origScheme];
            s = [s stringByReplacingOccurrencesOfString:cur withString:orig
                                             options:NSCaseInsensitiveSearch range:NSMakeRange(0, s.length)];
            deliverURL = [NSURL URLWithString:s] ?: url;
        }
        cleanupPending();

        // Call the stored completion handler with the (scheme-restored) callback URL
        handler(deliverURL, nil);
        return YES;
    }

    // Call original implementation
    if (s_orig_openURL) {
        return ((BOOL(*)(id, SEL, UIApplication *, NSURL *, NSDictionary *))
                s_orig_openURL)(self, _cmd, application, url, options);
    }
    return NO;
}

// ===== Hooks =====

%group ASWebAuthHooks

%hook ASWebAuthenticationSession

- (instancetype)initWithURL:(NSURL *)url
        callbackURLScheme:(NSString *)scheme
       completionHandler:(void (^)(NSURL *, NSError *))handler {
    ASWebAuthenticationSession *ret = %orig;

    if (!s_bypassHook && url && scheme) {
        // Capture the real callback scheme so the external-browser callback can
        // be delivered back to the session's completion handler regardless of
        // what scheme TrollRecorder uses.
        s_pendingURL     = [url copy];
        s_pendingScheme  = [scheme copy];
        s_origScheme     = [scheme copy];
        s_pendingHandler = [handler copy];
        s_pendingSession = ret;
        s_hasPending     = YES;
    }

    return ret;
}

- (BOOL)start {
    // Bypass: internal session creation (e.g. Safari ephemeral from picker)
    if (s_bypassHook) {
        return %orig;
    }

    // Not intercepting or plugin disabled
    if (!s_hasPending || !trpEnabled()) {
        return %orig;
    }

    NSInteger mode = trpMode();

    switch (mode) {
        case TRP_DISABLED:
        case TRP_SAFARI_DEFAULT:
            // Native behavior — the ASWebAuthenticationSession itself will
            // deliver the callback to the completion handler.
            s_externalFlow = NO;
            return %orig;

        case TRP_SAFARI_EPHEMERAL:
            // Set ephemeral flag then start natively
            s_externalFlow = NO;
            self.prefersEphemeralWebBrowserSession = YES;
            return %orig;

        case TRP_ALOOK:
        case TRP_CHROME:
        case TRP_QUARK:
            // Redirect to an external browser. TrollRecorder's auth callback scheme
            // is owned by another app (e.g. sileo://), so a real browser would hand
            // the callback to that app instead of TrollRecorder. When TrollRecorder
            // registers its own scheme we retarget the callback to it (openExternal),
            // so the result comes back here. If it registers no scheme, an external
            // browser cannot deliver the callback — fall back to an ephemeral Safari
            // session (isolated cookies, returns in-process to TrollRecorder).
            if (g_appScheme && g_appScheme.length) {
                s_externalFlow = YES;
                openExternal(s_pendingURL, mode);
                setupAutoCancel();
                return YES;  // Pretend session started
            }
            s_externalFlow = NO;
            self.prefersEphemeralWebBrowserSession = YES;
            return %orig;

        case TRP_ASK:
            // Show picker — callback will be delivered either by us (external
            // browser chosen, retargeted to TrollRecorder's scheme) or by a new
            // native session (Safari modes).
            s_externalFlow = YES;
            showBrowserPicker(s_pendingURL);
            setupAutoCancel();
            return YES;

        default:
            s_externalFlow = NO;
            return %orig;
    }
}

%end // %hook ASWebAuthenticationSession

%end // %group ASWebAuthHooks

%group AppDelegateHooks

%hook UIApplication

- (void)setDelegate:(id<UIApplicationDelegate>)delegate {
    %orig;

    if (delegate && !s_delegateSwizzled) {
        Class dc = object_getClass(delegate);
        SEL sel = @selector(application:openURL:options:);
        Method m = class_getInstanceMethod(dc, sel);

        if (m) {
            const char *types = method_getTypeEncoding(m);

            // Store original IMP
            s_orig_openURL = method_getImplementation(m);

            // Try to add method (for classes that inherit the method)
            // If add fails, the class already implements it — replace IMP
            if (!class_addMethod(dc, sel, (IMP)swizzled_openURL_impl, types)) {
                method_setImplementation(m, (IMP)swizzled_openURL_impl);
            }
        }

        s_delegateSwizzled = YES;
    }
}

%end // %hook UIApplication

%end // %group AppDelegateHooks

// ===== Constructor =====
%ctor {
    trpLoadAppScheme();
    %init(ASWebAuthHooks);
    %init(AppDelegateHooks);

    NSLog(@"[TrollRecorderBrowserPicker] v%@ loaded (appScheme=%@)", TRP_VERSION, g_appScheme);
}
