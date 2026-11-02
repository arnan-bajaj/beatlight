// orgb.h — minimal OpenRGB SDK client: drives every RGB device OpenRGB controls
// (Logitech mice, headsets, mousepads, ...) with one color at a time.
//
// Plain C with its own worker thread, so it can be unit-tested anywhere.
// Talks to OpenRGB's SDK server on 127.0.0.1 (OpenRGB > SDK Server > Start Server).

#ifndef ORGB_H
#define ORGB_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ORGB_DEFAULT_PORT 6742

// Enabling starts connecting in the background, retrying every few seconds until
// OpenRGB's SDK server answers, then switches each device to its Direct mode.
// Disabling puts every device back to the mode and colors it had, then disconnects;
// it waits (up to ~3 s) for that to finish. Call from one thread (the main thread).
void ORGBSetEnabled(bool enabled, uint16_t port);

// Sets every device to one color. Any thread; cheap; only the latest color is sent.
void ORGBSetColor(uint8_t r, uint8_t g, uint8_t b);

bool ORGBIsConnected(void);
int  ORGBDeviceCount(void);                         // 0 when not connected
bool ORGBDeviceName(int i, char *buf, size_t len);  // false if i is out of range

#ifdef __cplusplus
}
#endif

#endif
