//
//  AppGroup.m
//  iSH
//
//  Created by Theodore Dubois on 2/28/20.
//

#import "AppGroup.h"
#import <Foundation/Foundation.h>
#import <mach-o/ldsyms.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <dlfcn.h>

#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define CSMAGIC_EMBEDDED_ENTITLEMENTS 0xfade7171

struct cs_blob_index {
    uint32_t type;
    uint32_t offset;
};

struct cs_superblob {
    uint32_t magic;
    uint32_t length;
    uint32_t count;
    struct cs_blob_index index[];
};

struct cs_entitlements {
    uint32_t magic;
    uint32_t length;
    char entitlements[];
};

static NSDictionary *AppEntitlements(void) {
    static NSDictionary *entitlements;
    if (entitlements != nil)
        return entitlements;
    
    // Inspired by codesign.c in Darwin sources for Security.framework
    
    const struct mach_header_64 *header = &_mh_execute_header;
    
    // Simulator executables have fake entitlements in the code signature. The real entitlements can be found in an __entitlements section.
    size_t entitlements_size;
    char *entitlements_data = (char *) getsectiondata(header, "__TEXT", "__entitlements", &entitlements_size);
    if (entitlements_data != NULL) {
        NSData *data = [NSData dataWithBytesNoCopy:entitlements_data
                                            length:entitlements_size
                                      freeWhenDone:NO];
        return entitlements = [NSPropertyListSerialization propertyListWithData:data
                                                                        options:NSPropertyListImmutable
                                                                         format:nil
                                                                          error:nil];
    }
    
    // Find the LC_CODE_SIGNATURE
    struct load_command *lc = (void *) (header + 1);
    struct linkedit_data_command *cs_lc = NULL;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (lc->cmd == LC_CODE_SIGNATURE) {
            cs_lc = (void *) lc;
            break;
        }
        lc = (void *) ((char *) lc + lc->cmdsize);
    }
    if (cs_lc == NULL)
        return nil;

    // Read the code signature off disk, as it's apparently not loaded into memory
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingFromURL:NSBundle.mainBundle.executableURL error:nil];
    if (fileHandle == nil)
        return nil;
    [fileHandle seekToFileOffset:cs_lc->dataoff];
    NSData *csData = [fileHandle readDataOfLength:cs_lc->datasize];
    [fileHandle closeFile];
    const struct cs_superblob *cs = csData.bytes;
    if (ntohl(cs->magic) != CSMAGIC_EMBEDDED_SIGNATURE)
        return nil;
    
    // Find the entitlements in the code signature
    NSData *entitlementsData = nil;
    for (uint32_t i = 0; i < ntohl(cs->count); i++) {
        struct cs_entitlements *ents = (void *) ((char *) cs + ntohl(cs->index[i].offset));
        if (ntohl(ents->magic) == CSMAGIC_EMBEDDED_ENTITLEMENTS) {
            entitlementsData = [NSData dataWithBytes:ents->entitlements
                                              length:ntohl(ents->length) - offsetof(struct cs_entitlements, entitlements)];
        }
    }
    if (entitlementsData == nil)
        return nil;
    
    return entitlements = [NSPropertyListSerialization propertyListWithData:entitlementsData
                                                                    options:NSPropertyListImmutable
                                                                     format:nil
                                                                      error:nil];
}

NSArray<NSString *> *CurrentAppGroups(void) {
    return AppEntitlements()[@"com.apple.security.application-groups"];
}

NSURL *ContainerURL(void) {
    NSArray<NSString *> *groups = CurrentAppGroups();
    NSString *appGroup = groups.count > 0 ? groups[0] : nil;
    if (appGroup == nil) {
        // Dev build with stripped entitlements — use Application Support instead of
        // Documents. UIFileSharingEnabled (Info.plist) is disabled, and even if it were
        // re-enabled, the fakefs root databases must never sit in the user-visible
        // Documents folder (they would be exportable / editable via Files.app).
        // 老版本曾把 roots 放在 Documents: 首次启动迁移到新位置, 迁移失败则沿用旧位置。
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *support = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *legacyRoots = [docs URLByAppendingPathComponent:@"roots"];
        NSURL *newRoots = [support URLByAppendingPathComponent:@"roots"];
        if ([fm fileExistsAtPath:legacyRoots.path] && ![fm fileExistsAtPath:newRoots.path]) {
            NSError *moveError = nil;
            [fm createDirectoryAtURL:support withIntermediateDirectories:YES attributes:nil error:nil];
            if (![fm moveItemAtURL:legacyRoots toURL:newRoots error:&moveError]) {
                NSLog(@"AppGroup: moving legacy roots failed (%@), keeping Documents location", moveError.localizedDescription);
                return docs;
            }
        }
        return support;
    }
    return [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:appGroup];
}
