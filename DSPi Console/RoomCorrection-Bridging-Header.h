// Bridging header exposing the portable room-correction core to Swift.
//
// Only the C ABI is exposed.  The C++ headers stay on the C++ side of the
// boundary so the app never depends on the core's internal types, which is what
// keeps the core swappable and the Windows port honest.
#import "dspi_rc/capi.h"
