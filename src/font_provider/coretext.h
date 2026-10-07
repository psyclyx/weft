// CoreText family resolution behind a C ABI (coretext.c), for
// font_provider/coretext.zig. CoreFoundation is a C API, but its headers lean
// on blocks and Apple extensions translate-c need not follow; C reads them as
// written.

#ifndef WEFT_FONT_CORETEXT_H
#define WEFT_FONT_CORETEXT_H

#include <stddef.h>

// The file and PostScript name of the face CoreText matches for `family`
// with the given traits (NUL-terminated into the buffers). 0 on a match.
int weft_coretext_match(const char* family, int bold, int italic,
                        char* path, size_t path_cap, char* postscript, size_t postscript_cap);

#endif  // WEFT_FONT_CORETEXT_H
