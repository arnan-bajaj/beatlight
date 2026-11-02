// Beatlight.app — menu bar front end for the beatlight engine (engine.m).
// Lives in the menu bar only (LSUIElement): no Dock icon, no windows.
// Settings are saved with NSUserDefaults; it resumes running on launch if it was running when quit.

#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import "engine.h"
#import "orgb.h"
#include <signal.h>

static NSString *const kSource      = @"source";        // @"system" or @"mic"
static NSString *const kBacklight   = @"backlight";
static NSString *const kHaptics     = @"haptics";
static NSString *const kArp         = @"arp";
static NSString *const kHapticID    = @"hapticID";      // 3, 4, 6
static NSString *const kBeatSens    = @"beatSens";
static NSString *const kArpSens     = @"arpSens";
static NSString *const kWasRunning  = @"wasRunning";
static NSString *const kRGB         = @"rgb";
static NSString *const kRGBColor    = @"rgbColor";      // 0xRRGGBB
static NSString *const kRGBMode     = @"rgbMode";       // BLRGBMode
static NSString *const kRGBCycleOld = @"rgbCycle";      // pre-rgbMode setting, migrated on launch

static NSString *const kScreenSettingsURL = @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";
static NSString *const kMicSettingsURL    = @"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone";
static NSString *const kRepoURL           = @"https://github.com/arnan-bajaj/beatlight";
static NSString *const kRGBHelpURL        = @"https://github.com/arnan-bajaj/beatlight#rgb-devices-openrgb";

typedef NS_ENUM(NSInteger, BLState) { BLStateStopped, BLStateStarting, BLStateRunning };

@interface BLAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *item;
@property (assign) BLState state;
@property (copy) NSString *problem;            // why it last stopped, shown in the menu
@property (assign) NSUInteger startToken;      // ignores completions from superseded starts
@property (assign) BOOL resumeAfterWake;
@property (assign) BOOL retriedAfterFailure;
@property (assign) BOOL needsRestart;          // permission granted this run only applies after a restart
@end

@implementation BLAppDelegate

#pragma mark Lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        kSource: @"system", kBacklight: @YES, kHaptics: @YES, kArp: @NO,
        kHapticID: @4, kBeatSens: @1.6, kArpSens: @1.5, kWasRunning: @YES,
        kRGB: @NO, kRGBColor: @0xFFFFFF, kRGBMode: @(BLRGBSolid),
    }];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kRGBCycleOld]) [defaults setInteger:BLRGBKickCycle forKey:kRGBMode];
    [defaults removeObjectForKey:kRGBCycleOld];

    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    menu.autoenablesItems = NO;
    self.item.menu = menu;
    [self updateIcon];

    __weak BLAppDelegate *weakSelf = self;
    BLSetFailureHandler(^(NSString *reason) { [weakSelf engineFailed:reason]; });

    NSNotificationCenter *ws = NSWorkspace.sharedWorkspace.notificationCenter;
    [ws addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [ws addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];

    if ([NSUserDefaults.standardUserDefaults boolForKey:kWasRunning]) [self startShowingErrors:YES];
}

- (void)applicationWillTerminate:(NSNotification *)note {
    BLStop();   // restores the keyboard backlight; wasRunning is kept so it resumes next launch
}

#pragma mark Running

- (BLOptions)options {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BLOptions o = BLDefaultOptions();
    o.useMic    = [[d stringForKey:kSource] isEqualToString:@"mic"];
    o.backlight = [d boolForKey:kBacklight];
    o.haptics   = [d boolForKey:kHaptics];
    o.arp       = [d boolForKey:kArp];
    o.hapticID  = (int)[d integerForKey:kHapticID];
    o.sens      = [d doubleForKey:kBeatSens];
    o.arpSens   = [d doubleForKey:kArpSens];
    o.rgb       = [d boolForKey:kRGB];
    o.rgbColor  = (uint32_t)[d integerForKey:kRGBColor];
    o.rgbMode   = (BLRGBMode)[d integerForKey:kRGBMode];
    return o;
}

- (void)startShowingErrors:(BOOL)showErrors {
    if (self.state != BLStateStopped) return;
    self.state = BLStateStarting;
    self.problem = nil;
    NSUInteger token = ++self.startToken;
    [self updateIcon];

    BLStart([self options], ^(BLError code, NSString *message) {
        if (token != self.startToken) return;   // stopped or restarted meanwhile
        if (code == BLErrorNone) {
            self.state = BLStateRunning;
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:kWasRunning];
            // A run that lasts 30 s re-arms the one automatic retry after a failure.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (token == self.startToken && self.state == BLStateRunning) self.retriedAfterFailure = NO;
            });
            [self updateIcon];
            return;
        }
        self.state = BLStateStopped;
        self.problem = [self shortProblem:code message:message];
        if (code == BLErrorScreenPermission) self.needsRestart = YES;
        [self updateIcon];
        if (showErrors) [self showStartError:code message:message];
    });
}

- (void)stopByUser {
    self.startToken++;
    BLStop();
    self.state = BLStateStopped;
    self.problem = nil;
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kWasRunning];
    [self updateIcon];
}

- (void)restart {
    if (self.state == BLStateStopped) return;
    self.startToken++;
    BLStop();
    self.state = BLStateStopped;
    [self startShowingErrors:YES];
}

// Capture died while running (engine already stopped). Try once more after a moment.
- (void)engineFailed:(NSString *)reason {
    self.startToken++;
    self.state = BLStateStopped;
    self.problem = [self truncated:reason];
    [self updateIcon];
    if (self.retriedAfterFailure) return;
    self.retriedAfterFailure = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.state == BLStateStopped && [NSUserDefaults.standardUserDefaults boolForKey:kWasRunning])
            [self startShowingErrors:NO];
    });
}

- (void)willSleep:(NSNotification *)note {
    if (self.state == BLStateStopped) return;
    self.resumeAfterWake = YES;
    self.startToken++;
    BLStop();
    self.state = BLStateStopped;
    [self updateIcon];
}

- (void)didWake:(NSNotification *)note {
    if (!self.resumeAfterWake) return;
    self.resumeAfterWake = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.state == BLStateStopped) [self startShowingErrors:NO];
    });
}

#pragma mark Errors

- (NSString *)truncated:(NSString *)s {
    if (s.length <= 70) return s;
    return [[s substringToIndex:69] stringByAppendingString:@"…"];
}

// Engine messages are written for the CLI ("beatlight: no permission ..."); capitalize for UI.
- (NSString *)sentence:(NSString *)s {
    if (s.length == 0) return @"Unknown error.";
    return [[[s substringToIndex:1] uppercaseString] stringByAppendingString:[s substringFromIndex:1]];
}

- (NSString *)shortProblem:(BLError)code message:(NSString *)message {
    switch (code) {
        case BLErrorScreenPermission: return @"Needs Screen & System Audio Recording permission";
        case BLErrorMicPermission:    return @"Needs microphone permission";
        case BLErrorNoOutputs:        return @"Backlight, trackpad and RGB are all off or unavailable";
        case BLErrorCancelled:
        case BLErrorNone:             return nil;
        default:                      return [self truncated:[self sentence:message]];
    }
}

- (NSModalResponse)alert:(NSString *)title info:(NSString *)info buttons:(NSArray<NSString *> *)buttons {
    if (@available(macOS 14.0, *)) [NSApp activate];
    else [NSApp activateIgnoringOtherApps:YES];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = title;
    a.informativeText = info;
    for (NSString *b in buttons) [a addButtonWithTitle:b];
    return [a runModal];
}

- (void)openURL:(NSString *)url {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
}

- (void)showStartError:(BLError)code message:(NSString *)message {
    switch (code) {
        case BLErrorScreenPermission: {
            NSModalResponse r = [self alert:@"Beatlight needs permission to hear your Mac's audio"
                info:@"Turn on Beatlight in System Settings > Privacy & Security > Screen & System Audio Recording "
                     @"(the top list, not \"System Audio Recording Only\"). Then choose Restart Beatlight from the "
                     @"menu bar icon: macOS only applies the permission after a restart.\n\n"
                     @"macOS files audio capture under screen recording. Beatlight ignores the screen and only uses the audio."
                buttons:@[@"Open System Settings", @"Use Microphone Instead", @"Cancel"]];
            if (r == NSAlertFirstButtonReturn) {
                [self openURL:kScreenSettingsURL];
            } else if (r == NSAlertSecondButtonReturn) {
                [NSUserDefaults.standardUserDefaults setObject:@"mic" forKey:kSource];
                [self startShowingErrors:YES];
            }
            break;
        }
        case BLErrorMicPermission:
            if ([self alert:@"Beatlight needs microphone permission"
                       info:@"Turn on Beatlight in System Settings > Privacy & Security > Microphone, "
                            @"or switch Audio Source back to System Audio."
                    buttons:@[@"Open System Settings", @"Cancel"]] == NSAlertFirstButtonReturn)
                [self openURL:kMicSettingsURL];
            break;
        case BLErrorCancelled:
        case BLErrorNone:
            break;
        default:
            [self alert:@"Beatlight couldn't start" info:[self sentence:message] buttons:@[@"OK"]];
            break;
    }
}

#pragma mark Status item

- (void)updateIcon {
    NSStatusBarButton *button = self.item.button;
    NSImage *img = [NSImage imageWithSystemSymbolName:@"waveform" accessibilityDescription:@"Beatlight"];
    if (img) {
        img.template = YES;
        button.image = img;
    } else {
        button.title = @"♪";
    }
    button.appearsDisabled = (self.state != BLStateRunning);
    button.toolTip = self.state == BLStateRunning ? @"Beatlight: running" : @"Beatlight: stopped";
}

#pragma mark Menu

- (NSMenuItem *)add:(NSString *)title action:(SEL)action to:(NSMenu *)menu {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    it.target = self;
    [menu addItem:it];
    return it;
}

- (void)addLabel:(NSString *)title to:(NSMenu *)menu {
    [self add:title action:nil to:menu].enabled = NO;
}

- (NSMenuItem *)addToggle:(NSString *)title key:(NSString *)key to:(NSMenu *)menu {
    NSMenuItem *it = [self add:title action:@selector(toggleSetting:) to:menu];
    it.representedObject = key;
    it.state = [NSUserDefaults.standardUserDefaults boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    return it;
}

- (NSMenuItem *)addChoice:(NSString *)title action:(SEL)action value:(id)value checked:(BOOL)checked to:(NSMenu *)menu {
    NSMenuItem *it = [self add:title action:action to:menu];
    it.representedObject = value;
    it.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    return it;
}

- (NSMenuItem *)addSubmenu:(NSString *)title to:(NSMenu *)menu {
    NSMenuItem *it = [self add:title action:nil to:menu];
    NSMenu *sub = [[NSMenu alloc] initWithTitle:title];
    sub.autoenablesItems = NO;
    it.submenu = sub;
    return it;
}

- (NSMenuItem *)addSensitivity:(NSString *)title key:(NSString *)key values:(NSArray<NSNumber *> *)values to:(NSMenu *)menu {
    NSMenuItem *parent = [self addSubmenu:title to:menu];
    NSArray<NSString *> *labels = @[@"Low (fewer)", @"Medium", @"High (more)"];
    double current = [NSUserDefaults.standardUserDefaults doubleForKey:key];
    for (NSUInteger i = 0; i < values.count && i < labels.count; i++) {
        [self addChoice:labels[i] action:@selector(setSensitivity:) value:@[key, values[i]]
                checked:fabs(current - values[i].doubleValue) < 1e-6 to:parent.submenu];
    }
    return parent;
}

// RGB devices through OpenRGB: toggle (with connection status), connected devices, color.
- (void)addRGBItemsTo:(NSMenu *)menu running:(BOOL)running enabled:(BOOL)rgbOn {
    NSString *title = @"RGB Devices (OpenRGB)";
    int count = BLRGBConnected() ? ORGBDeviceCount() : -1;
    if (running && rgbOn)
        title = count < 0 ? @"RGB Devices (waiting for OpenRGB…)"
                          : [NSString stringWithFormat:@"RGB Devices (%d via OpenRGB)", count];
    [self addToggle:title key:kRGB to:menu];
    if (running && rgbOn && count > 0) {
        char name[96];
        for (int i = 0; i < 8 && ORGBDeviceName(i, name, sizeof name); i++) {
            NSString *n = [NSString stringWithUTF8String:name] ?: @"Device";
            NSMenuItem *it = [self add:n action:nil to:menu];
            it.enabled = NO;
            it.indentationLevel = 1;
        }
    }

    NSMenuItem *color = [self addSubmenu:@"RGB Color" to:menu];
    color.enabled = rgbOn;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger mode = [d integerForKey:kRGBMode];
    NSInteger current = [d integerForKey:kRGBColor];
    NSArray *colors = @[@[@"White", @0xFFFFFF], @[@"Red", @0xFF0000], @[@"Orange", @0xFF5000], @[@"Yellow", @0xFFC800],
                        @[@"Green", @0x00FF00], @[@"Cyan", @0x00FFFF], @[@"Blue", @0x0000FF],
                        @[@"Purple", @0x8000FF], @[@"Pink", @0xFF1080]];
    for (NSArray *c in colors)
        [self addChoice:c[0] action:@selector(setRGBColor:) value:c[1]
                checked:mode == BLRGBSolid && current == [c[1] integerValue] to:color.submenu];
    [color.submenu addItem:NSMenuItem.separatorItem];
    // Cycle modes are stored as negative values: -(BLRGBMode).
    [self addChoice:@"Color Cycle (changes on kicks)" action:@selector(setRGBColor:) value:@(-BLRGBKickCycle)
            checked:mode == BLRGBKickCycle to:color.submenu];
    [self addChoice:@"Rainbow (smooth)" action:@selector(setRGBColor:) value:@(-BLRGBRainbow)
            checked:mode == BLRGBRainbow to:color.submenu];
    [self addChoice:@"Rainbow (speeds up with the music)" action:@selector(setRGBColor:) value:@(-BLRGBReactiveRainbow)
            checked:mode == BLRGBReactiveRainbow to:color.submenu];
    [self add:@"RGB Setup Help…" action:@selector(openRGBHelp:) to:menu];
}

// Rebuilt every time it opens, so checkmarks and status are always current.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL running = self.state == BLStateRunning;
    BOOL backlightOn = [d boolForKey:kBacklight];
    BOOL hapticsOn = [d boolForKey:kHaptics];
    BOOL rgbOn = [d boolForKey:kRGB];

    [self addLabel:(running ? @"Beatlight is running"
                    : self.state == BLStateStarting ? @"Beatlight is starting…" : @"Beatlight is stopped") to:menu];
    if (self.state == BLStateStopped && self.problem) [self addLabel:self.problem to:menu];
    if (self.needsRestart) [self add:@"Restart Beatlight (after granting permission)" action:@selector(relaunch:) to:menu];
    [self add:(self.state == BLStateStopped ? @"Start" : @"Stop") action:@selector(toggleRunning:) to:menu];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *source = [self addSubmenu:@"Audio Source" to:menu];
    BOOL mic = [[d stringForKey:kSource] isEqualToString:@"mic"];
    [self addChoice:@"System Audio" action:@selector(setSource:) value:@"system" checked:!mic to:source.submenu];
    [self addChoice:@"Microphone" action:@selector(setSource:) value:@"mic" checked:mic to:source.submenu];
    [self addSensitivity:@"Beat Sensitivity" key:kBeatSens values:@[@2.0, @1.6, @1.3] to:menu];
    [menu addItem:NSMenuItem.separatorItem];

    [self addToggle:(running && backlightOn && !BLBacklightActive() ? @"Keyboard Backlight (not available)"
                                                                      : @"Keyboard Backlight")
                key:kBacklight to:menu];
    [self addToggle:@"Arp Flicker" key:kArp to:menu].enabled = backlightOn || rgbOn;
    [self addSensitivity:@"Arp Sensitivity" key:kArpSens values:@[@2.0, @1.5, @1.3] to:menu].enabled =
        (backlightOn || rgbOn) && [d boolForKey:kArp];
    [menu addItem:NSMenuItem.separatorItem];

    [self addToggle:(running && hapticsOn && !BLHapticsActive() ? @"Trackpad Haptics (not available)"
                                                                  : @"Trackpad Haptics")
                key:kHaptics to:menu];
    NSMenuItem *strength = [self addSubmenu:@"Haptic Strength" to:menu];
    strength.enabled = hapticsOn;
    NSInteger hid = [d integerForKey:kHapticID];
    [self addChoice:@"Weak" action:@selector(setHapticID:) value:@3 checked:hid == 3 to:strength.submenu];
    [self addChoice:@"Medium" action:@selector(setHapticID:) value:@4 checked:hid == 4 to:strength.submenu];
    [self addChoice:@"Strong" action:@selector(setHapticID:) value:@6 checked:hid == 6 to:strength.submenu];
    [menu addItem:NSMenuItem.separatorItem];

    [self addRGBItemsTo:menu running:running enabled:rgbOn];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *login = [self add:@"Launch at Login" action:@selector(toggleLogin:) to:menu];
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn
                                                                                   : NSControlStateValueOff;
    [self add:@"View on GitHub" action:@selector(openRepo:) to:menu];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Beatlight" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];
}

#pragma mark Actions

- (void)toggleRunning:(id)sender {
    if (self.state == BLStateStopped) {
        self.retriedAfterFailure = NO;
        [self startShowingErrors:YES];
    } else {
        [self stopByUser];
    }
}

- (void)optionsChanged {
    BLUpdateOptions([self options]);
}

- (void)toggleSetting:(NSMenuItem *)sender {
    NSString *key = sender.representedObject;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:![d boolForKey:key] forKey:key];
    [self optionsChanged];
}

- (void)setSource:(NSMenuItem *)sender {
    NSString *value = sender.representedObject;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([[d stringForKey:kSource] isEqualToString:value]) return;
    [d setObject:value forKey:kSource];
    [self restart];   // no-op when stopped
}

- (void)setSensitivity:(NSMenuItem *)sender {
    NSArray *keyAndValue = sender.representedObject;
    [NSUserDefaults.standardUserDefaults setDouble:[keyAndValue[1] doubleValue] forKey:keyAndValue[0]];
    [self optionsChanged];
}

- (void)setHapticID:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:[sender.representedObject integerValue] forKey:kHapticID];
    [self optionsChanged];
}

- (void)setRGBColor:(NSMenuItem *)sender {
    NSInteger value = [sender.representedObject integerValue];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (value < 0) {
        [d setInteger:-value forKey:kRGBMode];
    } else {
        [d setInteger:BLRGBSolid forKey:kRGBMode];
        [d setInteger:value forKey:kRGBColor];
    }
    [self optionsChanged];
}

- (void)openRGBHelp:(id)sender {
    [self openURL:kRGBHelpURL];
}

- (void)toggleLogin:(id)sender {
    SMAppService *service = SMAppService.mainAppService;
    NSError *err = nil;
    BOOL ok = service.status == SMAppServiceStatusEnabled ? [service unregisterAndReturnError:&err]
                                                          : [service registerAndReturnError:&err];
    if (!ok) {
        [self alert:@"Couldn't change Launch at Login" info:err.localizedDescription ?: @"Unknown error." buttons:@[@"OK"]];
        return;
    }
    if (service.status == SMAppServiceStatusRequiresApproval &&
        [self alert:@"Allow Beatlight in Login Items"
               info:@"macOS needs you to approve it in System Settings > General > Login Items."
            buttons:@[@"Open Login Items", @"Later"]] == NSAlertFirstButtonReturn)
        [SMAppService openSystemSettingsLoginItems];
}

// Quits and reopens the app, so a permission granted while it was running takes effect.
- (void)relaunch:(id)sender {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-c", @"sleep 1; /usr/bin/open \"$0\"", NSBundle.mainBundle.bundlePath];
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        [self alert:@"Couldn't restart Beatlight" info:@"Quit it from the menu and open it again." buttons:@[@"OK"]];
        return;
    }
    [NSApp terminate:nil];   // restores the backlight; the shell reopens the app a second later
}

- (void)openRepo:(id)sender {
    [self openURL:kRepoURL];
}

@end

#pragma mark - main

static BLAppDelegate *gDelegate;
static dispatch_source_t gSignals[2];

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        gDelegate = [[BLAppDelegate alloc] init];
        app.delegate = gDelegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        // `kill` or logout: quit normally so the backlight gets restored.
        int sigs[2] = { SIGINT, SIGTERM };
        for (int k = 0; k < 2; k++) {
            signal(sigs[k], SIG_IGN);
            gSignals[k] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sigs[k], 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(gSignals[k], ^{ [NSApp terminate:nil]; });
            dispatch_resume(gSignals[k]);
        }

        [app run];
    }
    return 0;
}
