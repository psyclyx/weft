// CoreText family resolution: see coretext.h.

#include "coretext.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <string.h>

// The generic family names weft asks for are fontconfig's (and CSS's)
// aliases; CoreText has families only. Each maps to a macOS family that ships
// with the system and has real bold and italic faces — static fonts, not a
// variable one whose instances would all load as its default.
static const char* familyFor(const char* requested) {
    static const struct {
        const char* generic;
        const char* family;
    } generics[] = {
        {"sans-serif", "Helvetica Neue"},
        {"serif", "Times New Roman"},
        {"monospace", "Menlo"},
    };
    for (size_t i = 0; i < sizeof generics / sizeof generics[0]; i++)
        if (strcmp(requested, generics[i].generic) == 0) return generics[i].family;
    return requested;
}

int weft_coretext_match(const char* requested, int bold, int italic,
                        char* path, size_t path_cap, char* postscript, size_t postscript_cap) {
    int result = 1;
    CFStringRef family = CFStringCreateWithCString(kCFAllocatorDefault, familyFor(requested), kCFStringEncodingUTF8);
    if (!family) return 1;

    const CTFontSymbolicTraits wanted = (bold ? kCTFontTraitBold : 0) | (italic ? kCTFontTraitItalic : 0);
    CFNumberRef symbolic = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &wanted);
    const void* trait_keys[] = {kCTFontSymbolicTrait};
    const void* trait_values[] = {symbolic};
    CFDictionaryRef traits = CFDictionaryCreate(kCFAllocatorDefault, trait_keys, trait_values, 1,
                                                &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
    const void* keys[] = {kCTFontFamilyNameAttribute, kCTFontTraitsAttribute};
    const void* values[] = {family, traits};
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                    &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef request = CTFontDescriptorCreateWithAttributes(attributes);
    // CoreText answers with its nearest face; for the traits that is the
    // point (no bold → regular), but a DIFFERENT family is not this one — it
    // may be LastResort, which draws every glyph as a box. Refuse it, and
    // the caller falls back to its embedded face.
    CTFontDescriptorRef match = request ? CTFontDescriptorCreateMatchingFontDescriptor(request, NULL) : NULL;
    if (match) {
        CFStringRef matched_family = CTFontDescriptorCopyAttribute(match, kCTFontFamilyNameAttribute);
        CFURLRef url = CTFontDescriptorCopyAttribute(match, kCTFontURLAttribute);
        CFStringRef ps = CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute);
        const Boolean same_family =
            matched_family && CFStringCompare(matched_family, family, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
        if (same_family && url && ps &&
            CFURLGetFileSystemRepresentation(url, true, (UInt8*)path, (CFIndex)path_cap) &&
            CFStringGetCString(ps, postscript, (CFIndex)postscript_cap, kCFStringEncodingUTF8))
            result = 0;
        if (matched_family) CFRelease(matched_family);
        if (url) CFRelease(url);
        if (ps) CFRelease(ps);
        CFRelease(match);
    }
    if (request) CFRelease(request);
    CFRelease(attributes);
    CFRelease(traits);
    CFRelease(symbolic);
    CFRelease(family);
    return result;
}
