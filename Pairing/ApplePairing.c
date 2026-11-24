#include "ODPairing.h"
#include <dispatch/dispatch.h>
#include <string.h>

int od_pair_export_apple(sec_protocol_metadata_t metadata, uint8_t output[32]) {
    dispatch_data_t secret = sec_protocol_metadata_create_secret(
        metadata, sizeof(OD_LAN_EXPORTER) - 1, OD_LAN_EXPORTER, 32);
    if (!secret) return 0;
    const void *bytes = NULL;
    size_t count = 0;
    dispatch_data_t mapped = dispatch_data_create_map(secret, &bytes, &count);
    int ok = mapped && count == 32;
    if (ok) memcpy(output, bytes, 32);
    if (mapped) dispatch_release(mapped);
    dispatch_release(secret);
    return ok;
}
