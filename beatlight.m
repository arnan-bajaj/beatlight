// beatlight — command-line front end: pulse a MacBook's keyboard backlight and
// trackpad haptics to music. The menu bar app (app.m) uses the same engine (engine.m).
//
// Build: ./build.sh     Run: ./beatlight --help

#import <Foundation/Foundation.h>
#import "engine.h"
#import "orgb.h"
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static BOOL gVerbose;

static void usage(void) {
    printf(
        "usage: beatlight [options]\n"
        "  --mic              listen through the microphone instead of system audio\n"
        "  --no-backlight     don't touch the keyboard backlight\n"
        "  --no-haptics       don't use the trackpad actuator\n"
        "  --min X            backlight floor, 0-1 (default 0.05)\n"
        "  --max X            backlight ceiling, 0-1 (default 1.0)\n"
        "  --sens X           beat threshold vs. running average, >1 (default 1.6; lower = more beats)\n"
        "  --haptic-rate N    max haptic pulses per second (default 4, hard cap 8)\n"
        "  --haptic-id N      actuation pattern: 3 weak, 4 medium, 6 strong (default 4)\n"
        "  --arp              flicker the keyboard backlight on synth/arpeggio notes (250 Hz-4 kHz)\n"
        "  --arp-sens X       arp threshold vs. running average, >1 (default 1.5; lower = more flickers)\n"
        "  --arp-depth X      backlight flicker strength, 0-1 (default 0.8)\n"
        "  --rgb              also pulse RGB devices through OpenRGB (its SDK server must be running)\n"
        "  --rgb-color RRGGBB pulse color for RGB devices, hex (default ffffff)\n"
        "  --rgb-cycle        step through colors, one step per kick, instead of one color\n"
        "  -v, --verbose      show a live level meter\n");
}

static double argNum(int argc, const char *argv[], int *i) {
    if (*i + 1 >= argc) { fprintf(stderr, "beatlight: %s needs a value\n", argv[*i]); exit(2); }
    char *end = NULL;
    const char *s = argv[++*i];
    double v = strtod(s, &end);
    if (end == s || *end != '\0') { fprintf(stderr, "beatlight: bad number '%s'\n", s); exit(2); }
    return v;
}

static uint32_t argHex(int argc, const char *argv[], int *i) {
    if (*i + 1 >= argc) { fprintf(stderr, "beatlight: %s needs a value\n", argv[*i]); exit(2); }
    const char *s = argv[++*i];
    if (s[0] == '#') s++;
    char *end = NULL;
    unsigned long v = strtoul(s, &end, 16);
    if (strlen(s) != 6 || *end != '\0') { fprintf(stderr, "beatlight: color must be 6 hex digits, like ff2200\n"); exit(2); }
    return (uint32_t)v;
}

static BLOptions parseArgs(int argc, const char *argv[]) {
    BLOptions o = BLDefaultOptions();
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if      (!strcmp(a, "--mic"))           o.useMic = YES;
        else if (!strcmp(a, "--no-backlight"))  o.backlight = NO;
        else if (!strcmp(a, "--no-haptics"))    o.haptics = NO;
        else if (!strcmp(a, "--min"))           o.minB = (float)argNum(argc, argv, &i);
        else if (!strcmp(a, "--max"))           o.maxB = (float)argNum(argc, argv, &i);
        else if (!strcmp(a, "--sens"))          o.sens = argNum(argc, argv, &i);
        else if (!strcmp(a, "--haptic-rate"))   o.hapticRate = argNum(argc, argv, &i);
        else if (!strcmp(a, "--haptic-id"))     o.hapticID = (int)argNum(argc, argv, &i);
        else if (!strcmp(a, "--arp"))           o.arp = YES;
        else if (!strcmp(a, "--arp-sens"))      o.arpSens = argNum(argc, argv, &i);
        else if (!strcmp(a, "--arp-depth"))     o.arpDepth = (float)argNum(argc, argv, &i);
        else if (!strcmp(a, "--rgb"))           o.rgb = YES;
        else if (!strcmp(a, "--rgb-color"))     o.rgbColor = argHex(argc, argv, &i);
        else if (!strcmp(a, "--rgb-cycle"))     o.rgbCycle = YES;
        else if (!strcmp(a, "-v") || !strcmp(a, "--verbose")) gVerbose = YES;
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); exit(0); }
        else { fprintf(stderr, "beatlight: unknown option %s\n", a); usage(); exit(2); }
    }
    if (o.hapticRate > BL_HAPTIC_RATE_CAP)
        fprintf(stderr, "beatlight: haptic rate capped at %.0f/s\n", BL_HAPTIC_RATE_CAP);
    if (o.arp && !o.backlight && !o.rgb)
        fprintf(stderr, "beatlight: --arp needs the backlight or --rgb; ignoring it.\n");
    return BLClampOptions(o);
}

static void stopAndExit(int code) {
    BOOL hadBacklight = BLBacklightActive();
    BLStop();   // restores the backlight level and auto-brightness
    if (hadBacklight) fprintf(stderr, "%sbeatlight: keyboard backlight restored.\n", gVerbose ? "\n" : "");
    exit(code);
}

static dispatch_source_t gSignals[2];
static dispatch_source_t gMeterTimer;
static dispatch_source_t gRGBTimer;

// Reports OpenRGB connection changes once a second.
static void watchRGB(void) {
    __block int lastCount = -1;
    gRGBTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gRGBTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(gRGBTimer, ^{
        int count = ORGBIsConnected() ? ORGBDeviceCount() : -1;
        if (count == lastCount) return;
        const char *nl = gVerbose ? "\n" : "";
        if (count < 0) {
            fprintf(stderr, "%sbeatlight: waiting for OpenRGB (open it and click SDK Server > Start Server)...\n", nl);
        } else {
            fprintf(stderr, "%sbeatlight: OpenRGB connected, %d device%s:\n", nl, count, count == 1 ? "" : "s");
            char name[96];
            for (int i = 0; ORGBDeviceName(i, name, sizeof name); i++) fprintf(stderr, "  %s\n", name);
        }
        lastCount = count;
    });
    dispatch_resume(gRGBTimer);
}

static void startMeter(void) {
    gMeterTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gMeterTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 80 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gMeterTimer, ^{
        BLMeter m = BLCurrentMeter();
        int bars = (int)lround(m.level * 30.0);
        if (bars < 0) bars = 0;
        if (bars > 30) bars = 30;
        char meter[31];
        memset(meter, '#', (size_t)bars);
        memset(meter + bars, ' ', (size_t)(30 - bars));
        meter[30] = '\0';
        fprintf(stderr, "\r[%s] %s %s", meter, m.beat ? "BEAT" : "    ", m.arp ? "ARP" : "   ");
    });
    dispatch_resume(gMeterTimer);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BLOptions opts = parseArgs(argc, argv);

        int sigs[2] = { SIGINT, SIGTERM };
        for (int k = 0; k < 2; k++) {
            signal(sigs[k], SIG_IGN);
            gSignals[k] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sigs[k], 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(gSignals[k], ^{ stopAndExit(0); });
            dispatch_resume(gSignals[k]);
        }

        BLSetFailureHandler(^(NSString *reason) {
            // The engine has already stopped and restored the backlight.
            fprintf(stderr, "\nbeatlight: %s\n", reason.UTF8String);
            exit(1);
        });

        BLStart(opts, ^(BLError code, NSString *message) {
            if (code != BLErrorNone) {
                fprintf(stderr, "beatlight: %s\n", message.UTF8String);
                if (code == BLErrorScreenPermission)
                    fprintf(stderr, "  Enable your terminal app there (Terminal, iTerm, ...), then quit and reopen it.\n"
                                    "  Or run with --mic to listen through the microphone instead.\n");
                exit(1);
            }
            if (opts.backlight && !BLBacklightActive())
                fprintf(stderr, "beatlight: keyboard backlight not reachable on this Mac; continuing without it.\n");
            if (opts.haptics && !BLHapticsActive())
                fprintf(stderr, "beatlight: trackpad actuator not reachable; continuing without haptics.\n");
            fprintf(stderr, "beatlight: listening %s. Ctrl-C to stop.\n",
                    opts.useMic ? "on the microphone" : "to system audio");
            if (opts.rgb) watchRGB();
            if (gVerbose) startMeter();
        });

        dispatch_main();
    }
}
