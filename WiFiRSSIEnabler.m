#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <substrate.h>

static const char signalNotification[] = "com.sahinkaa.wifirssienabler.signal";
static int readerToken = NOTIFY_TOKEN_INVALID;
static int currentRSSI;
static BOOL usesLegacyStatusBar;
static UIFont *legacyBatteryFont;
static uint64_t sampleUptime;
static char labelKey, maskKey;
static BOOL supportsControlCenterSizing;
static NSHashTable<UIView *> *signalViews;
static dispatch_source_t sampler;
static const CGFloat controlCenterPadding = 2;

static int numberRSSI(CFTypeRef property) {
    if (!property) return 0;
    if (CFGetTypeID(property) == CFDictionaryGetTypeID()) {
        property = CFDictionaryGetValue(property, CFSTR("RSSI_CTL_AGR"));
    }
    int value = 0;
    if (property && CFGetTypeID(property) == CFNumberGetTypeID() &&
        CFNumberGetValue(property, kCFNumberIntType, &value) &&
        value >= -127 && value <= -1) return value;
    return 0;
}

static void startSampling(void) {
    void *wifi = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi",
                        RTLD_LAZY | RTLD_LOCAL);
    if (!wifi) return;
    CFTypeRef (*createManager)(CFAllocatorRef, int) = dlsym(wifi, "WiFiManagerClientCreate");
    CFArrayRef (*copyDevices)(CFTypeRef) = dlsym(wifi, "WiFiManagerClientCopyDevices");
    CFTypeRef (*copyNetwork)(CFTypeRef) = dlsym(wifi, "WiFiDeviceClientCopyCurrentNetwork");
    CFTypeRef (*copyProperty)(CFTypeRef, CFStringRef) = dlsym(wifi, "WiFiDeviceClientCopyProperty");
    if (!createManager || !copyDevices || (!copyNetwork && !usesLegacyStatusBar) || !copyProperty) return;

    int writer = NOTIFY_TOKEN_INVALID;
    if (notify_register_check(signalNotification, &writer) != NOTIFY_STATUS_OK) return;
    dispatch_queue_t queue = dispatch_queue_create("com.sahinkaa.wifirssienabler.sample", DISPATCH_QUEUE_SERIAL);
    sampler = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(sampler, DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    __block CFTypeRef manager = NULL;
    dispatch_source_set_event_handler(sampler, ^{
        if (!manager) manager = createManager(kCFAllocatorDefault, 0);
        int reading = 0;
        CFArrayRef devices = manager ? copyDevices(manager) : NULL;
        if (devices) {
            CFIndex count = CFArrayGetCount(devices);
            for (CFIndex index = 0; index < count && !reading; index++) {
                CFTypeRef device = CFArrayGetValueAtIndex(devices, index);
                CFTypeRef network = copyNetwork ? copyNetwork(device) : NULL;
                // The legacy view still gates display on the system showing Wi-Fi.
                // Its interface RSSI can be readable even when the network object is not.
                if (!network && !usesLegacyStatusBar) continue;
                CFTypeRef property = copyProperty(device, CFSTR("RSSI"));
                reading = numberRSSI(property);
                if (property) CFRelease(property);
                if (network) CFRelease(network);
            }
            CFRelease(devices);
        }
        // Pack a timestamp so readers reject a sample left behind by a restart.
        uint64_t uptime = (uint64_t)NSProcessInfo.processInfo.systemUptime;
        notify_set_state(writer, reading ? (uptime << 8) | (uint64_t)-reading : 0);
        notify_post(signalNotification);
    });
    dispatch_resume(sampler);
}

static UIFont *batteryFont(UIView *view, NSUInteger depth) {
    const char *names[] = {"STUIStatusBarBatteryView", "_UIStatusBarBatteryView", "_UIBatteryView"};
    for (NSUInteger index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
        Class battery = objc_lookUpClass(names[index]);
        if (!battery || ![view isKindOfClass:battery]) continue;
        SEL selector = sel_registerName("percentageLabel");
        Method method = class_getInstanceMethod(object_getClass(view), selector);
        char type[2] = {0};
        id object = nil;
        if (method && method_getNumberOfArguments(method) == 2) {
            method_getReturnType(method, type, sizeof(type));
            if (type[0] == '@') object = ((id (*)(id, SEL))objc_msgSend)(view, selector);
        }
        if (usesLegacyStatusBar && ![object isKindOfClass:UILabel.class]) {
            Ivar ivar = class_getInstanceVariable(object_getClass(view), "_percentageLabel");
            const char *encoding = ivar ? ivar_getTypeEncoding(ivar) : NULL;
            if (encoding && encoding[0] == '@') object = object_getIvar(view, ivar);
        }
        if (![object isKindOfClass:UILabel.class]) continue;
        UILabel *label = object;
        if (label.attributedText.length) {
            id font = [label.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
            if ([font isKindOfClass:UIFont.class]) return font;
        }
        return label.font;
    }
    if (depth > 0) {
        for (UIView *child in view.subviews) {
            UIFont *font = batteryFont(child, depth - 1);
            if (font) return font;
        }
    }
    return nil;
}

// On older status bars the battery label may be outside the Wi-Fi view hierarchy.
static void observeLegacyBatteryFont(void) {
    Class battery = objc_lookUpClass("_UIBatteryView");
    if (!battery || ![battery isSubclassOfClass:UIView.class]) return;
    SEL selector = sel_registerName("_updatePercentageFont");
    Method method = class_getInstanceMethod(battery, selector);
    if (!method || method_getNumberOfArguments(method) != 2) return;
    char type[2] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'v') return;

    __block IMP original = NULL;
    IMP hook = imp_implementationWithBlock(^(UIView *view) {
        ((void (*)(UIView *, SEL))original)(view, selector);
        if (!NSThread.isMainThread) return;
        UIFont *font = batteryFont(view, 0);
        if (font) legacyBatteryFont = font;
    });
    MSHookMessageEx(battery, selector, hook, &original);
}

static void restoreGlyph(UIView *view, UILabel *label, CALayer *mask) {
    if (mask && view.layer.mask == mask) view.layer.mask = nil;
    [label removeFromSuperview];
}

// Control Center places the Wi-Fi glyph immediately after the carrier text.
static UILabel *nearbyStatusLabel(UIView *node, UIView *parent, CGRect glyph,
                                  Class stringView, BOOL insideString, NSUInteger depth) {
    if (node.hidden || node.alpha < 0.01) return nil;
    insideString |= [node isKindOfClass:stringView];
    if (insideString && [node isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)node;
        CGRect rect = [label convertRect:label.bounds toView:parent];
        CGFloat gap = CGRectGetMinX(glyph) - CGRectGetMaxX(rect);
        if (label.text.length && !CGRectIsEmpty(rect) && gap >= -2 && gap <= 18 &&
            fabs(CGRectGetMidY(rect) - CGRectGetMidY(glyph)) <= 5) return label;
    }
    if (depth == 0) return nil;
    for (UIView *child in node.subviews.reverseObjectEnumerator) {
        UILabel *label = nearbyStatusLabel(child, parent, glyph, stringView, insideString, depth - 1);
        if (label) return label;
    }
    return nil;
}

static UIView *leftStatusBarForeground(UIView *view) {
    if (!view.window) return nil;
    CGRect glyphInWindow = [view convertRect:view.bounds toView:view.window];
    if (CGRectGetMidX(glyphInWindow) >= CGRectGetMidX(view.window.bounds)) return nil;

    for (UIView *ancestor = view.superview; ancestor && ancestor != view.window; ancestor = ancestor.superview) {
        if ([NSStringFromClass(ancestor.class) hasSuffix:@"StatusBarForegroundView"]) return ancestor;
    }
    return nil;
}

static UILabel *controlCenterCarrierLabel(UIView *view, UIView *foreground) {
    if (!foreground) return nil;
    Class stringView = objc_lookUpClass(usesLegacyStatusBar ? "_UIStatusBarStringView" : "STUIStatusBarStringView");
    return stringView ? nearbyStatusLabel(foreground, view.superview, view.frame, stringView, NO, 6) : nil;
}

static UIFont *noCarrierRSSIFont(void) {
    static UIFont *font;
    if (!font) font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    return font;
}

static CGFloat controlCenterRSSIWidth(void) {
    static CGFloat width;
    if (width == 0) {
        NSDictionary *attributes = @{NSFontAttributeName: noCarrierRSSIFont()};
        CGFloat widest = 0;
        for (int magnitude = 10; magnitude <= 99; magnitude++) {
            NSString *reading = [NSString stringWithFormat:@"−%d", magnitude];
            CGFloat readingWidth = [reading sizeWithAttributes:attributes].width;
            widest = MAX(widest, readingWidth);
        }
        width = ceil(widest) + 2 * controlCenterPadding;
    }
    return width;
}

static void updateView(UIView *view) {
    UILabel *label = objc_getAssociatedObject(view, &labelKey);
    CALayer *mask = objc_getAssociatedObject(view, &maskKey);
    UIView *parent = view.superview;
    if (!currentRSSI || (uint64_t)NSProcessInfo.processInfo.systemUptime - sampleUptime > 15 || !view.window || !parent || view.hidden || view.alpha < 0.01 ||
        CGRectIsEmpty(view.bounds) || (view.layer.mask && view.layer.mask != mask)) {
        restoreGlyph(view, label, mask);
        return;
    }

    UIView *foreground = leftStatusBarForeground(view);
    UILabel *carrier = controlCenterCarrierLabel(view, foreground);
    BOOL noCarrier = supportsControlCenterSizing && foreground && !carrier;
    UIFont *font = usesLegacyStatusBar ? nil : carrier.font;
    if (!usesLegacyStatusBar && carrier.attributedText.length) {
        id attributedFont = [carrier.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
        if ([attributedFont isKindOfClass:UIFont.class]) font = attributedFont;
    }
    if (noCarrier) font = noCarrierRSSIFont();
    UIView *ancestor = parent;
    for (NSUInteger level = 0; ancestor && !font && level < 5; level++, ancestor = ancestor.superview) {
        font = batteryFont(ancestor, usesLegacyStatusBar ? 8 : 5);
    }
    if (!font && usesLegacyStatusBar) {
        font = legacyBatteryFont ?: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    }
    if (!font) {
        restoreGlyph(view, label, mask);
        return;
    }

    if (!label) {
        label = [UILabel new];
        label.userInteractionEnabled = NO;
        label.isAccessibilityElement = NO;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        objc_setAssociatedObject(view, &labelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (![label.font isEqual:font]) label.font = font;
    NSString *reading = [NSString stringWithFormat:@"−%d", -currentRSSI];
    if (![label.text isEqualToString:reading]) label.text = reading;
    CGSize size = [label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGRect frame = CGRectIntegral(CGRectMake(CGRectGetMidX(view.frame) - size.width / 2,
                                              CGRectGetMidY(view.frame) - size.height / 2,
                                              size.width, size.height));
    CGFloat space = [@" " sizeWithAttributes:@{NSFontAttributeName: font}].width;
    if (carrier) {
        CGRect textRect = [carrier textRectForBounds:carrier.bounds limitedToNumberOfLines:1];
        textRect = [carrier convertRect:textRect toView:parent];
        frame.origin.x = CGRectGetMaxX(textRect) + space;
        frame.origin.y = CGRectGetMidY(textRect) - frame.size.height / 2;
    } else if (noCarrier) {
        frame.origin.x = CGRectGetMinX(view.frame) + controlCenterPadding;
    } else if (usesLegacyStatusBar && CGRectGetMidX([view convertRect:view.bounds toView:view.window]) < CGRectGetMidX(view.window.bounds)) {
        frame.origin.x += space;
    }

    if (parent.clipsToBounds && !CGRectContainsRect(parent.bounds, frame)) {
        restoreGlyph(view, label, mask);
        return;
    }
    if (!CGRectEqualToRect(label.frame, frame)) label.frame = frame;
    if (label.alpha != view.alpha) label.alpha = view.alpha;
    if (label.superview != parent) [parent insertSubview:label aboveSubview:view];

    if (!mask) {
        mask = [CALayer layer];
        objc_setAssociatedObject(view, &maskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (view.layer.mask != mask) view.layer.mask = mask;
}

static void updateReading(void) {
    uint64_t state = 0;
    notify_get_state(readerToken, &state);
    uint64_t timestamp = state >> 8;
    uint64_t uptime = (uint64_t)NSProcessInfo.processInfo.systemUptime;
    unsigned int magnitude = state & 0xff;
    sampleUptime = timestamp;
    currentRSSI = timestamp <= uptime && uptime - timestamp <= 15 &&
        magnitude > 0 && magnitude <= 127 ? -(int)magnitude : 0;
    for (UIView *view in signalViews.allObjects) updateView(view);
}

static void observedView(UIView *view) {
    if (!NSThread.isMainThread) return;
    if (!signalViews) signalViews = [NSHashTable weakObjectsHashTable];
    [signalViews addObject:view];
    if (readerToken == NOTIFY_TOKEN_INVALID) {
        if (notify_register_dispatch(signalNotification, &readerToken, dispatch_get_main_queue(),
                                     ^(int token __unused) { updateReading(); }) == NOTIFY_STATUS_OK) {
            updateReading();
            return;
        }
    }
    updateView(view);
}

static void hookViewUpdate(Class cls, SEL selector) {
    if (!class_getInstanceMethod(cls, selector)) return;
    __block IMP original = NULL;
    IMP hook = imp_implementationWithBlock(^(UIView *view) {
        ((void (*)(UIView *, SEL))original)(view, selector);
        observedView(view);
    });
    MSHookMessageEx(cls, selector, hook, &original);
}

static CGSize controlCenterSize(UIView *view, CGSize stockSize) {
    if (NSThread.isMainThread && leftStatusBarForeground(view)) {
        // Keep the same width as carrier text appears or disappears.
        stockSize.width = controlCenterRSSIWidth();
    }
    return stockSize;
}

static void hookControlCenterSizing(Class wifi) {
    SEL intrinsicSelector = @selector(intrinsicContentSize);
    __block IMP originalIntrinsic = NULL;
    IMP intrinsicHook = imp_implementationWithBlock(^CGSize(UIView *view) {
        CGSize size = ((CGSize (*)(UIView *, SEL))originalIntrinsic)(view, intrinsicSelector);
        return controlCenterSize(view, size);
    });
    MSHookMessageEx(wifi, intrinsicSelector, intrinsicHook, &originalIntrinsic);

    SEL fittingSelector = @selector(sizeThatFits:);
    __block IMP originalFitting = NULL;
    IMP fittingHook = imp_implementationWithBlock(^CGSize(UIView *view, CGSize proposed) {
        CGSize size = ((CGSize (*)(UIView *, SEL, CGSize))originalFitting)(view, fittingSelector, proposed);
        return controlCenterSize(view, size);
    });
    MSHookMessageEx(wifi, fittingSelector, fittingHook, &originalFitting);
    supportsControlCenterSizing = YES;
}

__attribute__((constructor)) static void install(void) {
    NSInteger version = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    if (version < 16) return;
    usesLegacyStatusBar = version < 26;
    if (usesLegacyStatusBar) observeLegacyBatteryFont();

    Class wifi = Nil;
    if (version >= 26) {
        wifi = objc_lookUpClass("STUIStatusBarWifiSignalView");
        if (!wifi) {
            dlopen("/System/Library/PrivateFrameworks/SystemStatusUI.framework/SystemStatusUI",
                   RTLD_LAZY | RTLD_LOCAL);
            wifi = objc_lookUpClass("STUIStatusBarWifiSignalView");
        }
    }
    if (!wifi) wifi = objc_lookUpClass("_UIStatusBarWifiSignalView");
    if (wifi && [wifi isSubclassOfClass:UIView.class]) {
        if (wifi == objc_lookUpClass("STUIStatusBarWifiSignalView") &&
            [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            hookControlCenterSizing(wifi);
        }
        hookViewUpdate(wifi, @selector(layoutSubviews));
        hookViewUpdate(wifi, @selector(didMoveToWindow));
        hookViewUpdate(wifi, @selector(didMoveToSuperview));
        __block IMP originalHidden = NULL;
        SEL hidden = @selector(setHidden:);
        IMP hiddenHook = imp_implementationWithBlock(^(UIView *view, BOOL value) {
            ((void (*)(UIView *, SEL, BOOL))originalHidden)(view, hidden, value);
            if (NSThread.isMainThread) updateView(view);
        });
        MSHookMessageEx(wifi, hidden, hiddenHook, &originalHidden);

        __block IMP originalAlpha = NULL;
        SEL alpha = @selector(setAlpha:);
        IMP alphaHook = imp_implementationWithBlock(^(UIView *view, CGFloat value) {
            ((void (*)(UIView *, SEL, CGFloat))originalAlpha)(view, alpha, value);
            if (NSThread.isMainThread) updateView(view);
        });
        MSHookMessageEx(wifi, alpha, alphaHook, &originalAlpha);
    }
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ startSampling(); });
    }
}
