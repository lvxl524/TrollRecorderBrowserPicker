//
//  Interceptor.xm
//  TRPInterceptor  (global)
//
//  v1.0.5 — Globally injected interceptor. Its ONLY job: when a third-party
//  browser (or any non-Apple, non-TrollRecorder, non-Sileo app) tries to open a
//  `sileo://` URL WHILE a TrollRecorder login is pending, capture that URL,
//  stash it in a file, and post a cross-process Darwin notification so the
//  TrollRecorder-side dylib can deliver it to the original completionHandler.
//
//  This is what makes "log in with Alook, then the sileo:// callback is forced
//  back to TrollRecorder instead of Sileo" work. Safari is never involved.
//
//  Safety: the hook is a no-op unless BOTH:
//    - a pending flag file exists (set only during a TrollRecorder login), AND
//    - the URL scheme is exactly `sileo`.
//  Otherwise every openURL passes straight through (%orig). So normal Sileo
//  logins and all other URL opens are completely unaffected.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define TRP_PENDING_PATH @"/var/mobile/Library/Preferences/com.mosheng.trappbrowserpicker.pending"
#define TRP_RESULT_PATH  @"/var/mobile/Library/Preferences/com.mosheng.trappbrowserpicker.auth"
#define TRP_LOG_PATH     @"/var/mobile/Library/Preferences/com.mosheng.trappbrowserpicker.log"
#define TRP_NOTIFY_NAME  CFSTR("com.mosheng.trappbrowserpicker.auth")

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

// Should we act on a sileo:// openURL coming from the current process?
static BOOL trpShouldIntercept(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid) return NO;
    // Skip Apple system processes / daemons.
    if ([bid hasPrefix:@"com.apple."]) return NO;
    // Skip TrollRecorder itself (it must not intercept its own callbacks).
    if ([bid isEqualToString:@"wiki.qaq.trapp"]) return NO;
    // Skip Sileo (don't steal its own legitimate sileo:// handling).
    if ([bid localizedCaseInsensitiveContainsString:@"sileo"]) return NO;
    // Only act while a TrollRecorder login is actually pending.
    if (![[NSFileManager defaultManager] fileExistsAtPath:TRP_PENDING_PATH]) return NO;
    return YES;
}

// Capture the sileo:// URL and notify TrollRecorder. Returns YES if consumed.
static BOOL trpIntercept(NSURL *url) {
    if (!url) return NO;
    if (![url.scheme isEqualToString:@"sileo"]) return NO;
    if (!trpShouldIntercept()) return NO;

    NSString *s = url.absoluteString;
    [s writeToFile:TRP_RESULT_PATH atomically:YES
          encoding:NSUTF8StringEncoding error:nil];
    trpLog(@"Interceptor[%@]: captured sileo:// -> %@",
           [[NSBundle mainBundle] bundleIdentifier], s);

    // Clear the pending flag now so a stale timeout / second redirect can't
    // double-handle. The result file stays for TrollRecorder to read.
    [[NSFileManager defaultManager] removeItemAtPath:TRP_PENDING_PATH error:nil];

    // Cross-process wake-up. Darwin notify delivers the name only; the URL is
    // carried via the result file above.
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        TRP_NOTIFY_NAME, NULL, NULL, TRUE);
    trpLog(@"Interceptor: posted notification");
    return YES;
}

%group TRPInterceptorHooks

%hook UIApplication

- (BOOL)openURL:(NSURL *)url {
    if (trpIntercept(url)) return YES;
    return %orig;
}

- (BOOL)openURL:(NSURL *)url options:(NSDictionary<NSString *,id> *)options {
    if (trpIntercept(url)) return YES;
    return %orig;
}

- (void)openURL:(NSURL *)url
        options:(NSDictionary *)options
completionHandler:(void (^)(BOOL))completion {
    if (trpIntercept(url)) {
        if (completion) completion(YES);
        return;
    }
    %orig;
}

%end // %hook UIApplication

%end // %group TRPInterceptorHooks

%ctor {
    // Only hook where UIApplication exists (real apps). Daemons without it are
    // skipped — the per-call guards above are the real safety net anyway.
    if (objc_getClass("UIApplication")) {
        %init(TRPInterceptorHooks);
        trpLog(@"[TRPInterceptor] loaded into %@",
               [[NSBundle mainBundle] bundleIdentifier]);
    }
}
