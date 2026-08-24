//
//  Tweak.xm
//  TrollRecorderBrowserPicker  (TrollRecorder side)
//
//  v1.0.5 — Use a THIRD-PARTY browser (Alook/Chrome/Quark/custom) for
//  TrollRecorder's Havoc login, and intercept the `sileo://` callback inside
//  that browser, delivering it back to TrollRecorder. Safari is NEVER touched.
//
//  How it works (this is exactly what ASWebAuthenticationSession does, except
//  the web page is rendered in the chosen third-party browser instead of
//  Safari's shared session):
//
//   1. Hook ASWebAuthenticationSession / SFAuthenticationSession:
//        - initWithURL:callbackURLScheme:completionHandler:  → capture the
//          authURL, the callback scheme (`sileo`) and the completionHandler.
//        - start  → DON'T start the real Safari session. Instead set a "pending"
//          flag (a file) and open the authURL in the chosen third-party browser
//          via LSApplicationWorkspace `openURL:withOptions:` with the
//          `LSOpenInApplication` key (falls back to the browser's URL scheme).
//
//   2. The browser renders the Havoc login page using ITS OWN cookies (so the
//      user logs in with the browser's account, not Safari's).
//
//   3. On success Havoc redirects to `sileo://…`. The *global* interceptor
//      dylib (TRPInterceptor) catches that `sileo://` openURL inside the
//      browser, writes the full URL to a file and posts a cross-process
//      Darwin notification.
//
//   4. This dylib (running inside TrollRecorder) observes that notification,
//      reads the URL and calls the captured completionHandler with it — exactly
//      as if ASWebAuthenticationSession had intercepted the callback in-process.
//
//  Safari is completely untouched: we never read or write its cookies, and the
//  only thing we open in the browser is the Havoc login URL.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ===== Version =====
#define TRP_VERSION @"1.0.5"

// ===== Preferences =====
#define PREFS_PATH @"/var/mobile/Library/Preferences/com.mosheng.trappbrowserpicker.plist"
#define kEnabled      @"enabled"
#define kBrowserMode  @"browserMode"
#define kCustomBundle @"customBundleId"

// Browser modes
#define TRP_BROWSER_ALOOK   0
#define TRP_BROWSER_CHROME  1
#define TRP_BROWSER_QUARK   2
#define TRP_BROWSER_CUSTOM  3

// ===== Cross-process handshake files =====
#define TRP_PENDING_PATH @"/var/mobile/Library/Preferences/com.mosheng.trappbrowserpicker.pending"
#define TRP_RESULT_PATH  @"/var/mobile/Library/Preferences/com.mosheng.trappbrowserpicker.auth"
#define TRP_LOG_PATH     @"/var/mobile/Library/Preferences/com.mosheng.trappbrowserpicker.log"
#define TRP_NOTIFY_NAME  CFSTR("com.mosheng.trappbrowserpicker.auth")

// ASWebAuthenticationSessionError.canceledLogin = 10
#define TRP_CANCEL_CODE 10
#define TRP_ERROR_DOMAIN @"ASWebAuthenticationSessionErrorDomain"

// ===== Class declaration for compiler =====
@interface ASWebAuthenticationSession : NSObject
- (instancetype)initWithURL:(NSURL *)URL
        callbackURLScheme:(NSString *)callbackURLScheme
       completionHandler:(void (^)(NSURL *, NSError *))completionHandler;
- (BOOL)start;
@end

// ===== Captured session state =====
static NSURL   *g_authURL     = nil;
static NSString *g_scheme     = nil;
static void (^g_completion)(NSURL *, NSError *) = nil;
static BOOL    s_bypass       = NO;   // internal re-entry guard
static BOOL    s_delivered    = NO;   // already delivered a result?
static CFAbsoluteTime g_startTime = 0;

// ===== Logging (shared with the interceptor dylib) =====
static void trpLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:TRP_LOG_PATH];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:TRP_LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// ===== Preference helpers =====
static BOOL trpEnabled(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (!d) return YES;                  // no prefs yet → engage by default
    NSNumber *en = d[kEnabled];
    return en ? en.boolValue : YES;      // default ON
}

static NSInteger trpBrowserMode(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (!d) return TRP_BROWSER_ALOOK;
    NSNumber *m = d[kBrowserMode];
    return m ? m.integerValue : TRP_BROWSER_ALOOK;
}

static NSString *trpBrowserBundleId(void) {
    switch (trpBrowserMode()) {
        case TRP_BROWSER_CHROME:  return @"com.google.chrome.ios";
        case TRP_BROWSER_QUARK:   return @"com.quark.browser";
        case TRP_BROWSER_CUSTOM: {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
            NSString *c = d ? d[kCustomBundle] : nil;
            return (c && c.length > 0) ? c : @"com.ld.TakeBrowser";
        }
        case TRP_BROWSER_ALOOK:
        default: return @"com.ld.TakeBrowser";
    }
}

// Build a URL that opens `url` inside the chosen browser using its URL scheme
// (used only as a fallback when LSApplicationWorkspace is unavailable).
static NSString *trpBrowserSchemeURL(NSURL *url) {
    NSString *abs = url.absoluteString;
    switch (trpBrowserMode()) {
        case TRP_BROWSER_CHROME: {
            NSString *stripped = abs;
            if ([stripped hasPrefix:@"https://"]) stripped = [stripped substringFromIndex:8];
            else if ([stripped hasPrefix:@"http://"]) stripped = [stripped substringFromIndex:7];
            return [@"googlechrome://" stringByAppendingString:stripped];
        }
        case TRP_BROWSER_QUARK:
            return [@"quark://" stringByAppendingString:abs];
        case TRP_BROWSER_CUSTOM:
            // Unknown scheme for custom apps; caller falls back to LSApplicationWorkspace only.
            return abs;
        case TRP_BROWSER_ALOOK:
        default:
            return [@"Alook://" stringByAppendingString:abs];
    }
}

// Open `url` in the chosen third-party browser.
static void trpOpenInBrowser(NSURL *url) {
    NSString *bid = trpBrowserBundleId();
    trpLog(@"Opening auth URL in browser bundle: %@", bid);

    Class LSAW = objc_getClass("LSApplicationWorkspace");
    id ws = LSAW ? [LSAW performSelector:@selector(defaultWorkspace)] : nil;
    BOOL ok = NO;
    if (ws && [ws respondsToSelector:@selector(openURL:withOptions:)]) {
        NSDictionary *opts = @{ @"LSOpenInApplication" : bid };
        ok = (BOOL)[ws openURL:url withOptions:opts];
    }
    if (ok) {
        trpLog(@"Opened via LSApplicationWorkspace (LSOpenInApplication=%@)", bid);
        return;
    }

    // Fallback: browser URL scheme
    NSString *schemeURL = trpBrowserSchemeURL(url);
    NSURL *su = [NSURL URLWithString:schemeURL];
    if (su) {
        trpLog(@"Fallback scheme open: %@", schemeURL);
        [[UIApplication sharedApplication] openURL:su options:@{} completionHandler:nil];
    } else {
        trpLog(@"FAILED to open auth URL in browser (no LSAW, bad scheme)");
    }
}

static void trpSetPending(void) {
    [@"1" writeToFile:TRP_PENDING_PATH atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
}
static void trpClearPending(void) {
    [[NSFileManager defaultManager] removeItemAtPath:TRP_PENDING_PATH error:nil];
}
static void trpClearResult(void) {
    [[NSFileManager defaultManager] removeItemAtPath:TRP_RESULT_PATH error:nil];
}

// Deliver the captured `sileo://` URL to TrollRecorder's completionHandler.
static void trpDeliver(NSURL *callbackURL) {
    void (^h)(NSURL *, NSError *) = g_completion;
    g_completion = nil;
    g_authURL = nil;
    g_scheme = nil;
    s_delivered = YES;
    trpClearPending();
    trpClearResult();
    if (h) {
        dispatch_async(dispatch_get_main_queue(), ^{
            trpLog(@"Calling completionHandler with callback URL");
            h(callbackURL, nil);
        });
    }
}

static void trpCancel(void) {
    if (s_delivered) return;
    void (^h)(NSURL *, NSError *) = g_completion;
    g_completion = nil;
    g_authURL = nil;
    g_scheme = nil;
    s_delivered = YES;
    trpClearPending();
    trpClearResult();
    if (h) {
        NSError *err = [NSError errorWithDomain:TRP_ERROR_DOMAIN
                                            code:TRP_CANCEL_CODE
                                        userInfo:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            trpLog(@"Cancelling pending auth");
            h(nil, err);
        });
    }
}

// ===== Darwin notification callback (fired by the interceptor dylib) =====
static void trpAuthNotifyCallback(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    @autoreleasepool {
        if (s_delivered) return;
        NSString *s = [NSString stringWithContentsOfFile:TRP_RESULT_PATH
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
        if (!s || s.length == 0) {
            trpLog(@"Auth notification but empty result file");
            return;
        }
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSURL *cb = [NSURL URLWithString:s];
        trpLog(@"Received auth callback: %@", s);
        trpDeliver(cb);
    }
}

// Cancel if the user returns to TrollRecorder without completing (mimics the
// native "user cancelled" path so the app stays usable).
static void setupCancelOnReturn(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if (s_delivered) return;
        if (!g_completion) return;
        if (![[NSFileManager defaultManager] fileExistsAtPath:TRP_PENDING_PATH]) return;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - g_startTime > 20.0) {
            trpLog(@"Returned to app without auth result → cancel");
            trpCancel();
        }
    }];
}

// Safety net: clear the pending flag after 10 minutes so a forgotten/stale
// login can never make us steal a later legitimate `sileo://` (e.g. Sileo's
// own login). If a result arrives after this, it simply won't be delivered
// (acceptable edge case).
static void setupPendingTimeout(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * 60 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!s_delivered && g_completion) {
            trpLog(@"Pending flag timeout (10 min) → cancelling");
            trpCancel();
        }
    });
}

// ===== Hooks =====
%group TRPHooks

%hook ASWebAuthenticationSession

- (instancetype)initWithURL:(NSURL *)url
        callbackURLScheme:(NSString *)scheme
       completionHandler:(void (^)(NSURL *, NSError *))handler {
    instancetype ret = %orig;
    if (!s_bypass && url && scheme && trpEnabled()) {
        g_authURL    = [url copy];
        g_scheme     = [scheme copy];
        g_completion = [handler copy];
        s_delivered  = NO;
        g_startTime  = CFAbsoluteTimeGetCurrent();
        trpLog(@"Captured ASWebAuthenticationSession url=%@ scheme=%@", url, scheme);
    }
    return ret;
}

- (BOOL)start {
    if (s_bypass) return %orig;
    if (!trpEnabled() || !g_completion || s_delivered) return %orig;

    trpSetPending();
    g_startTime = CFAbsoluteTimeGetCurrent();
    NSURL *url = g_authURL;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (url) trpOpenInBrowser(url);
    });
    setupCancelOnReturn();
    setupPendingTimeout();
    trpLog(@"start: deferred to third-party browser (mode=%ld)", (long)trpBrowserMode());
    return YES;  // pretend the session started
}

%end // %hook ASWebAuthenticationSession

// Older API, identical shape.
%hook SFAuthenticationSession

- (instancetype)initWithURL:(NSURL *)url
        callbackURLScheme:(NSString *)scheme
       completionHandler:(void (^)(NSURL *, NSError *))handler {
    instancetype ret = %orig;
    if (!s_bypass && url && scheme && trpEnabled()) {
        g_authURL    = [url copy];
        g_scheme     = [scheme copy];
        g_completion = [handler copy];
        s_delivered  = NO;
        g_startTime  = CFAbsoluteTimeGetCurrent();
        trpLog(@"Captured SFAuthenticationSession url=%@ scheme=%@", url, scheme);
    }
    return ret;
}

- (BOOL)start {
    if (s_bypass) return %orig;
    if (!trpEnabled() || !g_completion || s_delivered) return %orig;

    trpSetPending();
    g_startTime = CFAbsoluteTimeGetCurrent();
    NSURL *url = g_authURL;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (url) trpOpenInBrowser(url);
    });
    setupCancelOnReturn();
    setupPendingTimeout();
    trpLog(@"SF start: deferred to third-party browser (mode=%ld)", (long)trpBrowserMode());
    return YES;
}

%end // %hook SFAuthenticationSession

%end // %group TRPHooks

// ===== Constructor =====
%ctor {
    %init(TRPHooks);
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        trpAuthNotifyCallback,
        TRP_NOTIFY_NAME,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    trpLog(@"[TrollRecorderBrowserPicker] v%@ loaded (enabled=%d mode=%ld)",
           TRP_VERSION, trpEnabled(), (long)trpBrowserMode());
}
