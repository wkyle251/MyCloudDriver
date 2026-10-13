#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <libkern/OSByteOrder.h>
#include <sys/mount.h>
#include <string.h>

// statfs's C function and structure share a name in Swift. This narrow bridge
// reads mount metadata only and never opens or scans the destination's files.
int32_t mcd_destination_bsd(const char *path, char *output, size_t capacity) {
    struct statfs volume;
    if (!path || !output || capacity == 0 || statfs(path, &volume) != 0) return -1;
    if (strncmp(volume.f_mntfromname, "/dev/", 5) != 0) return -1;
    size_t length = strnlen(volume.f_mntfromname, sizeof(volume.f_mntfromname));
    if (length < 6 || length == sizeof(volume.f_mntfromname) || length - 5 >= capacity) return -1;
    memcpy(output, volume.f_mntfromname + 5, length - 5);
    output[length - 5] = '\0';
    return 0;
}

// The SDK's NVMe interface is not exported by IOKit's Swift module map.
// Read only its existing health page; zero means unsupported/unavailable.
uint16_t mcd_nvme_temperature_kelvin(io_service_t service) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID,
                                         kIOCFPlugInInterfaceID, &plugin, &score) != kIOReturnSuccess || !plugin)
        return 0;
    IONVMeSMARTInterface **smart = NULL;
    HRESULT queried = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    uint16_t kelvin = 0;
    if (queried == S_OK && smart) {
        NVMeSMARTData data = {0};
        if ((*smart)->SMARTReadData(smart, &data) == kIOReturnSuccess)
            kelvin = OSSwapLittleToHostInt16(data.TEMPERATURE);
        (*smart)->Release(smart);
    }
    IODestroyPlugInInterface(plugin);
    return kelvin;
}
