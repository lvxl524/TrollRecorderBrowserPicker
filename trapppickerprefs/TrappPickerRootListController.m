//
//  TrappPickerRootListController.m
//  TrollRecorderBrowserPicker Settings
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Forward declare PSListController (provided by Preferences.app at runtime).
// IMPORTANT: do NOT declare the _specifiers ivar here — it belongs to the real
// PSListController and would create an undefined symbol
// (_OBJC_IVAR_$_PSListController._specifiers). Declare it in our own subclass.
@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name;
@end

@interface TrappPickerRootListController : PSListController {
    NSArray *_specifiers;
}
@end

@implementation TrappPickerRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"TrollRecorderBrowserPicker"];
    }
    return _specifiers;
}

- (NSString *)title {
    return @"巨魔录音机 浏览器选择";
}

@end
