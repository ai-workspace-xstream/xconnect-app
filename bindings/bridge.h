#ifndef BRIDGE_H
#define BRIDGE_H

#include <stdint.h>

char* WriteConfigFiles(const char* xrayPath,
                       const char* xrayContent,
                       const char* servicePath,
                       const char* serviceContent,
                       const char* vpnPath,
                       const char* vpnContent,
                       const char* password);

char* StartNodeService(const char* name);
char* StopNodeService(const char* name);
int32_t CheckNodeStatus(const char* name);
char* CreateWindowsService(const char* name,
                           const char* execPath,
                           const char* configPath);
char* PerformAction(const char* action, const char* password);
int32_t IsXrayDownloading(void);
char* StartXray(const char* config);
char* StopXray(void);
long long StartXrayTunnel(const char* config);
long long StartXrayTunnelWithFd(const char* config, int32_t tunFd, const char* interfaceName);
/* Explicit runtime tuning for one session: a negative value selects the
   default, memoryLimitMB 0 removes the Go soft limit. Out-of-range values
   fail the start with an error from GetLastXrayTunnelError. */
long long StartXrayTunnelWithFdTuned(const char* config,
                                     int32_t tunFd,
                                     const char* interfaceName,
                                     long long memoryLimitMB,
                                     int32_t gcPercent);
char* GetLastXrayTunnelError(void);
/* JSON: heapInUse, heapIdle, heapReleased, sys, numGC, goroutines,
   memoryLimit (bytes in effect), gcPercent (-1 outside a session). */
char* XrayTunnelMemoryStats(void);
int32_t SubmitInboundPacket(long long handle,
                            const uint8_t* data,
                            int32_t length,
                            int32_t protocol);
char* StopXrayTunnel(long long handle);
char* FreeXrayTunnel(long long handle);
void FreeCString(char* str);

#endif // BRIDGE_H
