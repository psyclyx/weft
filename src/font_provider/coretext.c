// CoreText family resolution: see coretext.h.

#include "coretext.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>

int weft_coretext_match(const char* family, int bold, int italic,
                        char* path, size_t path_cap, char* postscript, size_t postscript_cap) {
    int result = 1;
    CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, family, kCFStringEncodingUTF8);
    if (!name) return 1;

    const CTFontSymbolicTraits wanted = (bold ? kCTFontTraitBold : 0) | (italic ? kCTFontTraitItalic : 0);
    CFNumberRef symbolic = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &wanted);
    const void* trait_keys[] = {kCTFontSymbolicTrait};
    const void* trait_values[] = {symbolic};
    CFDictionaryRef traits = CFDictionaryCreate(kCFAllocatorDefault, trait_keys, trait_values, 1,
                                                &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
    const void* keys[] = {kCTFontFamilyNameAttribute, kCTFontTraitsAttribute};
    const void* values[] = {name, traits};
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                    &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef request = CTFontDescriptorCreateWithAttributes(attributes);
    // Like fontconfig's match, this always answers — with CoreText's nearest
    // face when the family or the traits don't exist exactly.
    CTFontDescriptorRef match = request ? CTFontDescriptorCreateMatchingFontDescriptor(request, NULL) : NULL;
    if (match) {
        CFURLRef url = CTFontDescriptorCopyAttribute(match, kCTFontURLAttribute);
        CFStringRef ps = CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute);
        if (url && ps &&
            CFURLGetFileSystemRepresentation(url, true, (UInt8*)path, (CFIndex)path_cap) &&
            CFStringGetCString(ps, postscript, (CFIndex)postscript_cap, kCFStringEncodingUTF8))
            result = 0;
        if (url) CFRelease(url);
        if (ps) CFRelease(ps);
        CFRelease(match);
    }
    if (request) CFRelease(request);
    CFRelease(attributes);
    CFRelease(traits);
    CFRelease(symbolic);
    CFRelease(name);
    return result;
}
