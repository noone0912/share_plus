// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#import "FPPSharePlusPlugin.h"
#import "LinkPresentation/LPLinkMetadata.h"
#import "LinkPresentation/LPMetadataProvider.h"

static NSString *const PLATFORM_CHANNEL = @"dev.fluttercommunity.plus/share";

// MARK: - Banking preference (bundle-id prefixes)
static NSArray<NSString *> *PreferredBundlePrefixes(void) {
  return @[
    @"com.paygo24.ababank",
    @"com.domain.acledabankqr",
    @"com.wingmoney.wingpay",
    @"kh.com.phillipbank.mobilebanking",
    @"com.sathapana.mBanking"
  ];
}

static BOOL ActivityTypeMatchesPreferred(UIActivityType _Nullable activityType) {
  if (!activityType) return NO;
  NSString *raw = activityType;
  for (NSString *prefix in PreferredBundlePrefixes()) {
    if ([raw containsString:prefix]) return YES;
  }
  return NO;
}

static UIViewController *RootViewController(void) {
  if (@available(iOS 13, *)) { // UIApplication.keyWindow is deprecated
    NSSet *scenes = [[UIApplication sharedApplication] connectedScenes];
    for (UIScene *scene in scenes) {
      if ([scene isKindOfClass:[UIWindowScene class]]) {
        NSArray *windows = ((UIWindowScene *)scene).windows;
        for (UIWindow *window in windows) {
          if (window.isKeyWindow) {
            return window.rootViewController;
          }
        }
      }
    }
    return nil;
  } else {
    return [UIApplication sharedApplication].keyWindow.rootViewController;
  }
}

static UIViewController *
TopViewControllerForViewController(UIViewController *viewController) {
  if (viewController.presentedViewController) {
    return TopViewControllerForViewController(
        viewController.presentedViewController);
  }
  if ([viewController isKindOfClass:[UINavigationController class]]) {
    return TopViewControllerForViewController(
        ((UINavigationController *)viewController).visibleViewController);
  }
  if ([viewController isKindOfClass:[UITabBarController class]]) {
    UIViewController *vc = ((UITabBarController *)viewController).selectedViewController ?: viewController;
    return TopViewControllerForViewController(vc);
  }
  return viewController;
}

// We need the companion to avoid ARC deadlock
@interface UIActivityViewSuccessCompanion : NSObject
@property FlutterResult result;
@property NSString *activityType;
@property BOOL completed;
- (id)initWithResult:(FlutterResult)result;
@end

@implementation UIActivityViewSuccessCompanion
- (id)initWithResult:(FlutterResult)result {
  if (self = [super init]) {
    self.result = result;
    self.completed = false;
  }
  return self;
}

// We use dealloc as the share-sheet might disappear and reappear (e.g. iCloud album)
- (void)dealloc {
  if (self.completed) {
    self.result(self.activityType);
  } else {
    self.result(@"");
  }
}
@end

@interface UIActivityViewSuccessController : UIActivityViewController
@property UIActivityViewSuccessCompanion *companion;
@end
@implementation UIActivityViewSuccessController
@end

@interface SharePlusData : NSObject <UIActivityItemSource>
@property(readonly, nonatomic, copy) NSString *subject;
@property(readonly, nonatomic, copy) NSString *text;
@property(readonly, nonatomic, copy) NSString *path;
@property(readonly, nonatomic, copy) NSString *mimeType;
- (instancetype)initWithSubject:(NSString *)subject
                           text:(NSString *)text NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFile:(NSString *)path
                    mimeType:(NSString *)mimeType NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFile:(NSString *)path
                    mimeType:(NSString *)mimeType
                     subject:(NSString *)subject NS_DESIGNATED_INITIALIZER;
- (instancetype)init
    __attribute__((unavailable("Use initWithSubject:text: instead")));
@end

@implementation SharePlusData
- (instancetype)init {
  [super doesNotRecognizeSelector:_cmd];
  return nil;
}
- (instancetype)initWithSubject:(NSString *)subject text:(NSString *)text {
  self = [super init];
  if (self) {
    _subject = [subject isKindOfClass:NSNull.class] ? @"" : subject;
    _text = text;
  }
  return self;
}
- (instancetype)initWithFile:(NSString *)path mimeType:(NSString *)mimeType {
  self = [super init];
  if (self) {
    _path = path;
    _mimeType = mimeType;
  }
  return self;
}
- (instancetype)initWithFile:(NSString *)path
                    mimeType:(NSString *)mimeType
                     subject:(NSString *)subject {
  self = [super init];
  if (self) {
    _path = path;
    _mimeType = mimeType;
    _subject = [subject isKindOfClass:NSNull.class] ? @"" : subject;
  }
  return self;
}

- (id)activityViewControllerPlaceholderItem:
    (UIActivityViewController *)activityViewController {
  return [self
      activityViewController:activityViewController
         itemForActivityType:@"dev.fluttercommunity.share_plus.placeholder"];
}

- (id)activityViewController:(UIActivityViewController *)activityViewController
         itemForActivityType:(UIActivityType)activityType {
  if (!_path || !_mimeType) {
    return _text;
  }
  // For placeholder, if image, return UIImage so preview appears
  if ([activityType isEqualToString:@"dev.fluttercommunity.share_plus.placeholder"] &&
      [_mimeType hasPrefix:@"image/"]) {
    UIImage *image = [UIImage imageWithContentsOfFile:_path];
    return image;
  }
  // Return NSURL for the real share to preserve filename and be treated as public.image
  NSURL *url = [NSURL fileURLWithPath:_path];
  return url;
}

- (NSString *)activityViewController:
                  (UIActivityViewController *)activityViewController
              subjectForActivityType:(UIActivityType)activityType {
  return _subject;
}

- (UIImage *)activityViewController:
                 (UIActivityViewController *)activityViewController
      thumbnailImageForActivityType:(UIActivityType)activityType
                      suggestedSize:(CGSize)suggestedSize {
  if (!_path || !_mimeType || ![_mimeType hasPrefix:@"image/"]) {
    return nil;
  }
  UIImage *image = [UIImage imageWithContentsOfFile:_path];
  return [self imageWithImage:image scaledToSize:suggestedSize];
}

- (UIImage *)imageWithImage:(UIImage *)image scaledToSize:(CGSize)newSize {
  UIGraphicsBeginImageContext(newSize);
  [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
  UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return newImage;
}

- (LPLinkMetadata *)activityViewControllerLinkMetadata:
    (UIActivityViewController *)activityViewController
    API_AVAILABLE(macos(10.15), ios(13.0), watchos(6.0)) {
  LPLinkMetadata *metadata = [[LPLinkMetadata alloc] init];

  if ([_subject length] > 0) {
    metadata.title = _subject;
  } else if ([_text length] > 0) {
    metadata.title = _text;
  }

  if (_path) {
    NSString *ext = [_path pathExtension];
    unsigned long long rawSize = ([[[NSFileManager defaultManager]
                                    attributesOfItemAtPath:_path
                                    error:nil] fileSize]);
    NSString *readableSize = [NSByteCountFormatter stringFromByteCount:rawSize
                                                            countStyle:NSByteCountFormatterCountStyleFile];
    NSString *desc = @"";
    if (![ext isEqualToString:@""]) {
      desc = [[ext uppercaseString] stringByAppendingFormat:@" • %@", readableSize];
    } else {
      desc = readableSize;
    }
    // Trick from SO to show a subtitle/description line
    metadata.originalURL = [NSURL fileURLWithPath:desc];
    if (_mimeType && [_mimeType hasPrefix:@"image/"]) {
      metadata.imageProvider = [[NSItemProvider alloc]
          initWithObject:[UIImage imageWithContentsOfFile:_path]];
    }
  }
  return metadata;
}
@end

@implementation FPPSharePlusPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *shareChannel =
      [FlutterMethodChannel methodChannelWithName:PLATFORM_CHANNEL
                                  binaryMessenger:registrar.messenger];

  [shareChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    NSDictionary *arguments = [call arguments];
    NSNumber *originX = arguments[@"originX"];
    NSNumber *originY = arguments[@"originY"];
    NSNumber *originWidth = arguments[@"originWidth"];
    NSNumber *originHeight = arguments[@"originHeight"];

    CGRect originRect = CGRectZero;
    if (originX && originY && originWidth && originHeight) {
      originRect = CGRectMake([originX doubleValue], [originY doubleValue],
                              [originWidth doubleValue], [originHeight doubleValue]);
    }

    if ([@"share" isEqualToString:call.method]) {
      NSString *shareText = arguments[@"text"];
      NSString *shareSubject = arguments[@"subject"];

      if (shareText.length == 0) {
        result([FlutterError errorWithCode:@"error"
                                   message:@"Non-empty text expected"
                                   details:nil]);
        return;
      }

      UIViewController *rootViewController = RootViewController();
      if (!rootViewController) {
        result([FlutterError errorWithCode:@"error"
                                   message:@"No root view controller found"
                                   details:nil]);
        return;
      }
      UIViewController *topViewController = TopViewControllerForViewController(rootViewController);

      [self shareText:shareText
              subject:shareSubject
       withController:topViewController
             atSource:originRect
             toResult:result];

    } else if ([@"shareFiles" isEqualToString:call.method]) {
      NSArray *paths = arguments[@"paths"];
      NSArray *mimeTypes = arguments[@"mimeTypes"];
      NSString *subject = arguments[@"subject"];
      NSString *text = arguments[@"text"];

      if (paths.count == 0) {
        result([FlutterError errorWithCode:@"error"
                                   message:@"Non-empty paths expected"
                                   details:nil]);
        return;
      }
      for (NSString *path in paths) {
        if (path.length == 0) {
          result([FlutterError errorWithCode:@"error"
                                     message:@"Each path must not be empty"
                                     details:nil]);
          return;
        }
      }

      UIViewController *rootViewController = RootViewController();
      if (!rootViewController) {
        result([FlutterError errorWithCode:@"error"
                                   message:@"No root view controller found"
                                   details:nil]);
        return;
      }
      UIViewController *topViewController = TopViewControllerForViewController(rootViewController);

      [self shareFiles:paths
          withMimeType:mimeTypes
           withSubject:subject
              withText:text
        withController:topViewController
              atSource:originRect
              toResult:result];

    } else if ([@"shareUri" isEqualToString:call.method]) {
      NSString *uri = arguments[@"uri"];

      if (uri.length == 0) {
        result([FlutterError errorWithCode:@"error"
                                   message:@"Non-empty uri expected"
                                   details:nil]);
        return;
      }

      UIViewController *rootViewController = RootViewController();
      if (!rootViewController) {
        result([FlutterError errorWithCode:@"error"
                                   message:@"No root view controller found"
                                   details:nil]);
        return;
      }
      UIViewController *topViewController = TopViewControllerForViewController(rootViewController);

      [self shareUri:uri
      withController:topViewController
            atSource:originRect
            toResult:result];
    } else {
      result(FlutterMethodNotImplemented);
    }
  }];
}

// Centralized share method — updated to mimic Swift ShareService behavior.
+ (void)share:(NSArray *)shareItems
  withSubject:(NSString *)subject
withController:(UIViewController *)controller
      atSource:(CGRect)origin
      toResult:(FlutterResult)result {

  UIActivityViewSuccessController *activityViewController =
      [[UIActivityViewSuccessController alloc] initWithActivityItems:shareItems
                                               applicationActivities:nil];

  // Force subject when sharing a raw url or files
  if (![subject isKindOfClass:[NSNull class]] && subject.length > 0) {
    [activityViewController setValue:subject forKey:@"subject"];
  }

  // Strongly reduce non-banking options (Apple does not allow strict whitelisting)
  NSMutableArray<UIActivityType> *excluded = [@[
    UIActivityTypePrint,
    UIActivityTypeAssignToContact,
    UIActivityTypeSaveToCameraRoll,
    UIActivityTypePostToFacebook,
    UIActivityTypePostToTwitter,
    UIActivityTypePostToWeibo,
    UIActivityTypeMessage,
    UIActivityTypeMail,
    UIActivityTypeCopyToPasteboard,
    UIActivityTypeAddToReadingList,
    UIActivityTypePostToVimeo,
    UIActivityTypePostToTencentWeibo,
    UIActivityTypePostToFlickr,
    UIActivityTypeAirDrop,
  ] mutableCopy];

  if (@available(iOS 11.0, *)) {
    [excluded addObject:UIActivityTypeOpenInIBooks];
    [excluded addObject:UIActivityTypeMarkupAsPDF];
  }
  activityViewController.excludedActivityTypes = excluded;

  activityViewController.popoverPresentationController.sourceView = controller.view;
  BOOL isCoordinateSpaceOfSourceView = CGRectContainsRect(controller.view.frame, origin);

  // On iPad, a popover sourceRect is required
  BOOL hasPopover = [activityViewController popoverPresentationController] != NULL;
  if (hasPopover && (!isCoordinateSpaceOfSourceView || CGRectIsEmpty(origin))) {
    // Default to centered popover if caller didn't pass a valid origin
    activityViewController.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(controller.view.bounds),
                   CGRectGetMidY(controller.view.bounds), 0, 0);
    activityViewController.popoverPresentationController.permittedArrowDirections = 0;
  } else if (!CGRectIsEmpty(origin)) {
    activityViewController.popoverPresentationController.sourceRect = origin;
  }

  UIActivityViewSuccessCompanion *companion =
      [[UIActivityViewSuccessCompanion alloc] initWithResult:result];
  activityViewController.companion = companion;
  activityViewController.completionWithItemsHandler =
      ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems,
        NSError *activityError) {
        if (activityError) {
          NSLog(@"⚠️ Share error: %@", activityError.localizedDescription);
        }
        if (completed) {
          BOOL preferred = ActivityTypeMatchesPreferred(activityType);
          NSLog(preferred ? @"🏦 Target matches preferred banking apps (%@)"
                          : @"ℹ️ Target not in preferred list (%@)", activityType);
        } else {
          NSLog(@"ℹ️ Share cancelled");
        }
        companion.activityType = activityType;
        companion.completed = completed;
      };

  [controller presentViewController:activityViewController
                           animated:YES
                         completion:^{
                           NSLog(@"📤 Presented filtered share sheet (banking-first)");
                         }];
}

+ (void)shareUri:(NSString *)uri
  withController:(UIViewController *)controller
        atSource:(CGRect)origin
        toResult:(FlutterResult)result {
  NSURL *data = [NSURL URLWithString:uri];
  [self share:@[ data ]
   withSubject:nil
withController:controller
      atSource:origin
      toResult:result];
}

+ (void)shareText:(NSString *)shareText
          subject:(NSString *)subject
   withController:(UIViewController *)controller
         atSource:(CGRect)origin
         toResult:(FlutterResult)result {
  NSObject *data = [[SharePlusData alloc] initWithSubject:subject text:shareText];
  [self share:@[ data ]
   withSubject:subject
withController:controller
      atSource:origin
      toResult:result];
}

+ (void)shareFiles:(NSArray *)paths
      withMimeType:(NSArray *)mimeTypes
       withSubject:(NSString *)subject
          withText:(NSString *)text
    withController:(UIViewController *)controller
          atSource:(CGRect)origin
          toResult:(FlutterResult)result {

  NSMutableArray *items = [[NSMutableArray alloc] init];

  // Prefer image URLs (public.image) — mirrors your Swift ImageItemSource approach.
  for (NSInteger i = 0; i < (NSInteger)paths.count; i++) {
    NSString *path = paths[i];
    NSString *mime = (i < (NSInteger)mimeTypes.count) ? mimeTypes[i] : @"";
    // Always provide file URL; if image/*, the preview & type are ideal for banking share extensions.
    [items addObject:[[SharePlusData alloc] initWithFile:path mimeType:mime subject:subject]];
  }

  // Optional extra text; keep last to mimic OS behavior.
  if (text != nil && text.length > 0) {
    NSObject *data = [[SharePlusData alloc] initWithSubject:subject text:text];
    [items addObject:data];
  }

  [self share:items
   withSubject:subject
withController:controller
      atSource:origin
      toResult:result];
}
@end
