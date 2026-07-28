// Compiles the portable core into the macOS app target.
//
// The core lives in Core/RoomCorrection so it can be built by CMake for CI and
// for the eventual Windows front end.  The Xcode project uses a synchronized
// root group over "DSPi Console", which picks up sources by location, so these
// one-line shims are how the same files reach the app target without keeping a
// second copy or hand-editing the file list on every change.
//
// One shim per source rather than a single unity file: each core source has its
// own anonymous-namespace helpers, and merging them into one translation unit
// would collide.
#include "../../Core/RoomCorrection/src/biquad.cpp"
