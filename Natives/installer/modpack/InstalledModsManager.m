#import "InstalledModsManager.h"
#import "ModrinthModInstallation.h"
#import "ModrinthAPI.h"
#import "CurseForgeAPI.h"
#import "ModrinthSearchFilters.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *IMString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSString *IMHash(NSData *data) {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH]; CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hash = [NSMutableString new]; for (NSUInteger i=0; i<sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]]; return hash;
}
static NSString *IMRoot(NSString *directory) { return [directory.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".amethyst-modrinth"]; }
static BOOL IMName(NSString *name) {
    return IMString(name).length && [name isEqual:name.lastPathComponent] && ![name containsString:@"\\"] && ![name hasPrefix:@"."] && ([name.lowercaseString hasSuffix:@".jar"] || [name.lowercaseString hasSuffix:@".jar.disabled"]);
}
static NSData *IMPayload(id value) { return [value isKindOfClass:NSData.class] ? value : [value isKindOfClass:NSString.class] ? [NSData dataWithContentsOfFile:value options:NSDataReadingMappedIfSafe error:nil] : nil; }

// logging stuff as [ModManager]
static void IMLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void IMLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    printf("[ModManager] %s\n", line.UTF8String);
    fflush(stdout);
}
static NSString *IMVersionName(NSDictionary *version) {
    NSString *name = IMString(version[@"version_number"]).length ? version[@"version_number"] : IMString(version[@"name"]);
    return [NSString stringWithFormat:@"%@ [project %@, version %@]", name.length ? name : @"?", IMString(version[@"project_id"]), IMString(version[@"id"])];
}
static NSString *IMFilterText(NSDictionary *filters) {
    return [NSString stringWithFormat:@"Minecraft %@, loader %@", IMString(filters[@"mcVersion"]), IMString(filters[@"loader"])];
}
static NSString *IMBuiltFor(NSDictionary *version) {
    NSArray *games = [version[@"game_versions"] isKindOfClass:NSArray.class] ? version[@"game_versions"] : @[];
    NSArray *loaders = [version[@"loaders"] isKindOfClass:NSArray.class] ? version[@"loaders"] : @[];
    return [NSString stringWithFormat:@"built for Minecraft [%@], loaders [%@]", [games componentsJoinedByString:@", "], [loaders componentsJoinedByString:@", "]];
}

static NSError *IMError(NSString *key, NSString *detail) {
    NSString *message = NSLocalizedString(key, nil);
    IMLog(@"ERROR %@ (%@) %@", key, message, detail.length ? [@"- " stringByAppendingString:detail] : @"");
    if (detail.length) message = [message stringByAppendingFormat:@"\n%@", detail];
    return [NSError errorWithDomain:@"InstalledMods" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static ModpackAPI *IMAPI(NSString *provider) { return [provider isEqual:@"curseforge"] ? [CurseForgeAPI new] : [ModrinthAPI new]; }
// Uses the network error when there is one (it is more useful), otherwise makes our own error.
static NSError *IMFail(ModpackAPI *api, NSString *key, NSString *detail) {
    if (api.lastError) { IMLog(@"ERROR network/API problem while resolving %@: %@", detail, api.lastError.localizedDescription); return api.lastError; }
    return IMError(key, detail);
}
static NSString *IMID(NSString *provider, NSString *project) { return [NSString stringWithFormat:@"%@:%@", provider, project]; }

// Remembers "what is the newest version" answers for 5 minutes so the list does not hit the network again after every install.
static NSMutableDictionary *IMCache(void) {
    static NSMutableDictionary *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    return cache;
}

static BOOL IMValidEntry(NSDictionary *entry, NSString *directory, NSError **error) {
    NSString *name = entry[@"filename"];
    NSDictionary *attrs = IMName(name) ? [NSFileManager.defaultManager attributesOfItemAtPath:[directory stringByAppendingPathComponent:name] error:error] : nil;
    if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || ![[ModrinthModInstallation sha1ForFile:[directory stringByAppendingPathComponent:name] error:error] isEqual:entry[@"sha1"]]) {
        IMLog(@"File check failed for %@ (missing, not a normal file, or it changed on disk)", name);
        if (error && !*error) *error = IMError(@"mods.install.changed_file", name);
        return NO;
    }
    return YES;
}

@implementation InstalledModsManager
+ (void)clearUpdateCache { @synchronized (IMCache()) { [IMCache() removeAllObjects]; } IMLog(@"Update cache cleared (fresh check requested)"); }
+ (void)logMessage:(NSString *)message { IMLog(@"%@", message ?: @""); }

+ (id)persistentObject:(id)object {
    if ([object isKindOfClass:NSDictionary.class]) { NSMutableDictionary *result = [NSMutableDictionary new]; for (id key in object) { id value = [self persistentObject:object[key]]; if ([key isKindOfClass:NSString.class] && value) result[key] = value; } return result; }
    if ([object isKindOfClass:NSArray.class]) { NSMutableArray *result = [NSMutableArray new]; for (id item in object) { id value = [self persistentObject:item]; if (value) [result addObject:value]; } return result; }
    return [object isKindOfClass:NSString.class] || [object isKindOfClass:NSNumber.class] || [object isKindOfClass:NSData.class] || [object isKindOfClass:NSDate.class] ? object : nil;
}

+ (NSArray *)entriesInDirectory:(NSString *)directory identify:(BOOL)identify error:(NSError **)error {
    if (![ModrinthModInstallation isInstalling] && ![self recoverDirectory:directory error:error]) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:directory]) return @[];
    NSArray *names = [fm contentsOfDirectoryAtPath:directory error:error];
    if (!names) { IMLog(@"ERROR could not read the mods folder %@: %@", directory, error ? (*error).localizedDescription : @""); return nil; }
    NSMutableDictionary *index = [[NSDictionary dictionaryWithContentsOfFile:[IMRoot(directory) stringByAppendingPathComponent:@"index.plist"]] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *projects = [[NSDictionary dictionaryWithContentsOfFile:[IMRoot(directory) stringByAppendingPathComponent:@"projects.plist"]] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableArray *entries = [NSMutableArray new], *unknown = [NSMutableArray new];
    for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        if (!IMName(name)) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        if (![[fm attributesOfItemAtPath:path error:nil][NSFileType] isEqual:NSFileTypeRegular]) continue;
        NSString *hash = [ModrinthModInstallation sha1ForFile:path error:error];
        if (!hash) { IMLog(@"ERROR could not read %@ to identify it", name); return nil; }
        NSString *provider = @"modrinth";
        NSDictionary *version = index[hash];
        if (!version && index[IMID(@"curseforge", hash)]) { provider = @"curseforge"; version = index[IMID(provider, hash)]; }
        NSMutableDictionary *entry = [@{@"filename": name, @"sha1": hash, @"enabled": @(![name.lowercaseString hasSuffix:@".disabled"]), @"provider": provider} mutableCopy];
        if (version) entry[@"version"] = version;
        else [unknown addObject:hash];
        [entries addObject:entry];
    }
    if (identify && unknown.count) {
        ModrinthAPI *api = [ModrinthAPI new];
        NSDictionary *resolved = [api versionsForFileHashes:unknown];
        // Keep local management available while offline; never call unknown files up-to-date.
        for (NSMutableDictionary *entry in entries) if (resolved[entry[@"sha1"]]) {
            entry[@"version"] = resolved[entry[@"sha1"]]; index[entry[@"sha1"]] = entry[@"version"];
        }
        if (api.lastError) {
            IMLog(@"WARNING could not look up %lu unknown file(s) online: %@", (unsigned long)unknown.count, api.lastError.localizedDescription);
            for (NSMutableDictionary *entry in entries) if (!entry[@"version"]) entry[@"lookupError"] = api.lastError.localizedDescription;
        }
    }
    for (NSMutableDictionary *entry in entries) {
        NSDictionary *version = entry[@"version"];
        NSString *project = IMString(version[@"project_id"]), *provider = entry[@"provider"];
        if (!project.length) { if (identify) IMLog(@"NOTE %@ is not recognised as a Modrinth/CurseForge mod, so it is not part of dependency checks", entry[@"filename"]); continue; }
        NSString *key = IMID(provider, project);
        NSDictionary *info = projects[key];
        if (identify && !info) { info = [IMAPI(provider) projectForID:project]; if (info) projects[key] = info; }
        entry[@"project"] = info ?: @{@"id": project, @"provider": provider, @"contentType": @"mod", @"title": IMString(version[@"name"]).length ? version[@"name"] : entry[@"filename"], @"description": @"", @"author": @"", @"imageUrl": @""};
    }
    if (identify) {
        IMLog(@"Scanned %@: %lu mod file(s), %lu not recognised", directory, (unsigned long)entries.count, (unsigned long)[entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, NSDictionary *b) { return !e[@"version"]; }]].count);
        @synchronized (self) {
        NSMutableDictionary *fresh = [[NSDictionary dictionaryWithContentsOfFile:[IMRoot(directory) stringByAppendingPathComponent:@"index.plist"]] mutableCopy] ?: [NSMutableDictionary new];
        [fresh addEntriesFromDictionary:index]; index = fresh;
        [fm createDirectoryAtPath:IMRoot(directory) withIntermediateDirectories:YES attributes:nil error:nil];
        [[self persistentObject:index] writeToFile:[IMRoot(directory) stringByAppendingPathComponent:@"index.plist"] atomically:YES];
        [[self persistentObject:projects] writeToFile:[IMRoot(directory) stringByAppendingPathComponent:@"projects.plist"] atomically:YES];
        }
    }
    return entries;
}
+ (NSArray *)checkUpdates:(NSArray *)entries filters:(NSDictionary *)filters {
    NSMutableArray *result = [NSMutableArray new]; NSMutableDictionary *catalog = [NSMutableDictionary new];
    for (NSDictionary *entry in entries) {
        NSMutableDictionary *row = entry.mutableCopy;
        NSString *project = IMString(entry[@"version"][@"project_id"]), *provider = entry[@"provider"];
        if (project.length) {
            NSString *key = IMID(provider, project);
            NSString *cacheKey = [NSString stringWithFormat:@"%@|%@|%@", key, IMString(filters[@"mcVersion"]), IMString(filters[@"loader"])];
            NSDictionary *cached; @synchronized (IMCache()) { cached = IMCache()[cacheKey]; }
            NSDictionary *status = catalog[key] ?: ([cached[@"time"] timeIntervalSinceNow] > -300 ? cached[@"status"] : nil);
            ModpackAPI *api = IMAPI(provider);
            if (!status) {
                NSArray *versions = [api versionsForProject:project filters:filters];
                if (versions) versions = [ModrinthSearchFilters versions:versions matchingFilters:filters];
                NSDictionary *latest;
                for (NSDictionary *version in [versions sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"date_published" ascending:NO]]]) if (![version[@"downloadUnavailable"] boolValue] && [ModrinthModInstallation jarFileForVersion:version]) { latest = version; break; }
                status = @{@"latest": latest ?: @{}, @"error": api.lastError.localizedDescription ?: @"", @"checked": @(versions != nil)};
                catalog[key] = status;
                if ([status[@"checked"] boolValue]) @synchronized (IMCache()) { IMCache()[cacheKey] = @{@"time": NSDate.date, @"status": status}; }
                if (!versions) IMLog(@"WARNING update check failed for %@ (%@): %@", entry[@"filename"], key, api.lastError.localizedDescription ?: @"no details");
                else if (!latest) IMLog(@"NOTE %@ (%@): no version exists for %@", entry[@"filename"], key, IMFilterText(filters));
            }
            NSDictionary *current = entry[@"version"];
            if (!current[@"dependencies"]) current = [api versionForID:current[@"id"] projectID:project] ?: current;
            row[@"version"] = current;
            NSString *message = [status[@"error"] length] ? status[@"error"] : api.lastError.localizedDescription;
            if (message.length) row[@"updateError"] = message;
            row[@"updatesChecked"] = status[@"checked"];
            NSDictionary *latest = status[@"latest"];
            NSString *currentDate = IMString(row[@"version"][@"date_published"]), *latestDate = IMString(latest[@"date_published"]);
            if (latest.count && ![latest[@"id"] isEqual:row[@"version"][@"id"]] && currentDate.length && [latestDate compare:currentDate] == NSOrderedDescending) { row[@"update"] = latest; IMLog(@"Update available: %@ -> %@", IMVersionName(row[@"version"]), IMVersionName(latest)); }
            if (!latest.count && [status[@"checked"] boolValue]) row[@"noCompatibleVersion"] = @YES;
        }
        [result addObject:row];
    }
    return result;
}
+ (NSArray *)planForEntries:(NSArray *)entries requested:(NSArray *)requested filters:(NSDictionary *)filters error:(NSError **)error {
    IMLog(@"PLAN start: %@, %lu installed file(s), %lu requested change(s)", IMFilterText(filters), (unsigned long)entries.count, (unsigned long)requested.count);
    if (!IMString(filters[@"mcVersion"]).length || !IMString(filters[@"loader"]).length) { if (error) *error = IMError(@"mods.installed.profile_required", nil); return nil; }
    NSMutableDictionary *installedIDs = [NSMutableDictionary new]; // mods that are enabled right now and what version they are
    NSMutableDictionary *selected = [NSMutableDictionary new], *providers = [NSMutableDictionary new], *explicit = [NSMutableDictionary new], *pins = [NSMutableDictionary new], *disabled = [NSMutableDictionary new];
    for (NSDictionary *entry in entries) {
        NSString *project = IMString(entry[@"version"][@"project_id"]), *provider = entry[@"provider"];
        if (!project.length || ![entry[@"enabled"] boolValue]) continue;
        NSString *key = IMID(provider, project);
        if (selected[key] && ![selected[key][@"id"] isEqual:entry[@"version"][@"id"]]) { IMLog(@"CONFLICT two different versions of the same mod are installed: %@ and %@ (file %@)", IMVersionName(selected[key]), IMVersionName(entry[@"version"]), entry[@"filename"]); if (error) *error = IMError(@"mods.installed.conflict", project); return nil; }
        NSDictionary *version = entry[@"version"];
        if (!version[@"dependencies"]) { ModpackAPI *api = IMAPI(provider); version = [api versionForID:version[@"id"] projectID:project]; if (!version) { if (error) *error = IMFail(api, @"mods.installed.unresolved", project); return nil; } }
        if (![ModrinthSearchFilters versions:@[version] matchingFilters:filters].count) { IMLog(@"UNRESOLVED installed mod %@ (file %@) does not match the profile: profile is %@, but it is %@", IMVersionName(version), entry[@"filename"], IMFilterText(filters), IMBuiltFor(version)); if (error) *error = IMError(@"mods.installed.unresolved", project); return nil; }
        selected[key] = version; providers[key] = provider; installedIDs[key] = version[@"id"];
    }
    for (NSDictionary *request in requested) {
        NSDictionary *version = request[@"version"]; NSString *provider = request[@"provider"] ?: @"modrinth", *project = IMString(version[@"project_id"]);
        if (!project.length || ![ModrinthSearchFilters versions:@[version] matchingFilters:filters].count) { IMLog(@"UNRESOLVED requested version %@ does not match the profile: profile is %@, but it is %@", IMVersionName(version), IMFilterText(filters), IMBuiltFor(version)); if (error) *error = IMError(@"mods.installed.unresolved", project); return nil; }
        NSString *key = IMID(provider, project); selected[key] = version; explicit[key] = version[@"id"]; providers[key] = provider; disabled[key] = request[@"disabled"] ?: @NO;
        IMLog(@"Requested: %@ (%@)", IMVersionName(version), [disabled[key] boolValue] ? @"to be disabled" : @"to be enabled");
    }
    // Revisit dependencies after pinned versions replace a candidate. Detect cycles by version ID.
    NSMutableSet *visited = [NSMutableSet new]; NSMutableArray *queue = selected.allKeys.mutableCopy;
    NSUInteger steps = 0;
    while (queue.count) {
        if (++steps > 512 || selected.count > 128) { IMLog(@"CONFLICT dependency resolution did not finish (too many steps or mods, possibly a dependency loop)"); if (error) *error = IMError(@"mods.installed.conflict", nil); return nil; }
        NSString *key = queue.firstObject; [queue removeObjectAtIndex:0];
        NSDictionary *version = selected[key]; NSString *provider = providers[key];
        if ([disabled[key] boolValue]) continue;
        NSString *visit = [key stringByAppendingFormat:@":%@", version[@"id"]];
        if ([visited containsObject:visit]) continue; [visited addObject:visit];
        for (id dep in [version[@"dependencies"] isKindOfClass:NSArray.class] ? version[@"dependencies"] : @[]) {
            if (![dep isKindOfClass:NSDictionary.class] || ![dep[@"dependency_type"] isEqual:@"required"]) continue;
            NSString *project = IMString(dep[@"project_id"]), *pin = IMString(dep[@"version_id"]);
            IMLog(@"%@ requires project %@ %@", IMVersionName(version), project.length ? project : @"(unknown project)", pin.length ? [@"at exactly version " stringByAppendingString:pin] : @"(any compatible version)");
            ModpackAPI *api = IMAPI(provider); NSDictionary *candidate;
            if (pin.length) { candidate = [api versionForID:pin projectID:project]; if (!candidate) { if (error) *error = IMFail(api, @"mods.installed.unresolved", pin); return nil; } project = IMString(candidate[@"project_id"]); }
            if (!project.length) { IMLog(@"UNRESOLVED %@ lists a required dependency with no project id (file name %@)", IMVersionName(version), IMString(dep[@"file_name"])); if (error) *error = IMError(@"mods.installed.unresolved", IMString(dep[@"file_name"])); return nil; }
            NSString *depKey = IMID(provider, project);
            if (pin.length && ((pins[depKey] && ![pins[depKey] isEqual:pin]) || (explicit[depKey] && ![explicit[depKey] isEqual:pin]))) { IMLog(@"CONFLICT %@ needs version %@ of project %@, but another mod (or your request) needs version %@", IMVersionName(version), pin, project, pins[depKey] ?: explicit[depKey]); if (error) *error = IMError(@"mods.installed.conflict", project); return nil; }
            if (pin.length) pins[depKey] = pin;
            if (!candidate) {
                candidate = selected[depKey];
                if (!candidate) for (NSDictionary *entry in entries) if ([entry[@"provider"] isEqual:provider] && [entry[@"version"][@"project_id"] isEqual:project]) { candidate = [api versionForID:entry[@"version"][@"id"] projectID:project]; break; }
                if (candidate && ![ModrinthSearchFilters versions:@[candidate] matchingFilters:filters].count) { IMLog(@"NOTE already installed %@ does not match %@ (%@), looking for another version", IMVersionName(candidate), IMFilterText(filters), IMBuiltFor(candidate)); candidate = nil; }
                if (!candidate) {
                    NSArray *versions = [[ModrinthSearchFilters versions:[api versionsForProject:project filters:filters] matchingFilters:filters] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"date_published" ascending:NO]]];
                    for (NSDictionary *value in versions) if (![value[@"downloadUnavailable"] boolValue] && [ModrinthModInstallation jarFileForVersion:value]) { candidate = value; break; }
                    if (!candidate) IMLog(@"NOTE no downloadable version of required project %@ exists for %@ (needed by %@; %lu version(s) matched the filters)", project, IMFilterText(filters), IMVersionName(version), (unsigned long)versions.count);
                }
            }
            if (!candidate || ![candidate[@"project_id"] isEqual:project] || ![ModrinthSearchFilters versions:@[candidate] matchingFilters:filters].count) {
                // Some mods list a dependency that only exists for another loader (e.g. "Kotlin for Forge" on a Fabric version).
                // A Fabric profile can never use it, so when the project has no version for this loader at all, it is skipped.
                if (!candidate && [provider isEqual:@"modrinth"]) {
                    NSMutableDictionary *anyVersion = [filters mutableCopy]; anyVersion[@"mcVersion"] = @""; anyVersion[@"loader"] = @"";
                    NSArray *everything = [api versionsForProject:project filters:anyVersion];
                    NSMutableSet *supportedLoaders = [NSMutableSet new];
                    for (NSDictionary *other in everything) if ([other[@"loaders"] isKindOfClass:NSArray.class]) [supportedLoaders addObjectsFromArray:other[@"loaders"]];
                    if (everything.count && ![supportedLoaders containsObject:IMString(filters[@"loader"])]) {
                        IMLog(@"NOTE skipped dependency: %@ lists project %@ as required, but that project only supports [%@] and never %@, so it cannot apply to this profile (https://modrinth.com/project/%@)", IMVersionName(version), project, [supportedLoaders.allObjects componentsJoinedByString:@", "], IMString(filters[@"loader"]), project);
                        continue;
                    }
                }
                // An already-enabled mod that is not part of this change must not block it just because one of ITS dependencies has no version for this profile.
                if ([installedIDs[key] isEqual:version[@"id"]] && !explicit[key]) { IMLog(@"WARNING skipped: installed mod %@ needs project %@, which has no version for %@. This mod is not part of the current change, so it is left as it is (check that project on Modrinth: https://modrinth.com/project/%@).", IMVersionName(version), project, IMFilterText(filters), project); continue; }
                if (candidate) IMLog(@"UNRESOLVED chosen dependency %@ does not fit: %@, project wanted %@", IMVersionName(candidate), IMFilterText(filters), project); if (error) *error = IMFail(api, @"mods.installed.unresolved", project); return nil; }
            if (pins[depKey] && ![pins[depKey] isEqual:candidate[@"id"]]) { IMLog(@"CONFLICT project %@ must be version %@ but the chosen version is %@", project, pins[depKey], candidate[@"id"]); if (error) *error = IMError(@"mods.installed.conflict", project); return nil; }
            if (!selected[depKey] || ![selected[depKey][@"id"] isEqual:candidate[@"id"]]) { selected[depKey] = candidate; providers[depKey] = provider; [queue addObject:depKey]; IMLog(@"  -> using %@", IMVersionName(candidate)); }
            // Required dependencies are enabled, including previously disabled files.
            disabled[depKey] = @NO;
        }
    }
    // Check incompatibilities against the final enabled set, including existing dependents.
    for (NSString *key in selected) {
        if ([disabled[key] boolValue]) continue;
        for (NSDictionary *dep in selected[key][@"dependencies"] ?: @[]) {
            if (![dep[@"dependency_type"] isEqual:@"incompatible"]) continue;
            NSString *project = IMString(dep[@"project_id"]), *pin = IMString(dep[@"version_id"]);
            if (!project.length && pin.length) project = IMString([IMAPI(providers[key]) versionForID:pin projectID:@""][@"project_id"]);
            NSString *depKey = IMID(providers[key], project);
            if (selected[depKey] && ![disabled[depKey] boolValue] && (!pin.length || [pin isEqual:selected[depKey][@"id"]])) { IMLog(@"CONFLICT %@ is marked incompatible with %@, but both would be enabled", IMVersionName(selected[key]), IMVersionName(selected[depKey])); if (error) *error = IMError(@"mods.installed.conflict", project); return nil; }
        }
    }
    NSMutableArray *plan = [NSMutableArray new];
    for (NSString *key in [selected.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *version = selected[key]; NSString *provider = providers[key];
        NSMutableArray *previous = [NSMutableArray new];
        for (NSDictionary *entry in entries) if ([entry[@"provider"] isEqual:provider] && [entry[@"version"][@"project_id"] isEqual:version[@"project_id"]]) [previous addObject:entry];
        BOOL same = previous.count == 1 && [previous[0][@"version"][@"id"] isEqual:version[@"id"]] && [previous[0][@"enabled"] boolValue] == ![disabled[key] boolValue];
        if (!same) [plan addObject:@{@"version":version, @"provider":provider, @"previous":previous, @"disabled":disabled[key] ?: @NO}];
    }
    IMLog(@"PLAN done: %lu change(s)", (unsigned long)plan.count);
    for (NSDictionary *item in plan) IMLog(@"  plan: %@ replaces %@", IMVersionName(item[@"version"]), [[item[@"previous"] valueForKey:@"filename"] componentsJoinedByString:@", "] ?: @"nothing");
    return plan;
}
+ (BOOL)setEntry:(NSDictionary *)entry enabled:(BOOL)enabled directory:(NSString *)directory error:(NSError **)error {
    if ([ModrinthModInstallation isInstalling]) { if (error) *error = IMError(@"mods.install.busy", nil); return NO; }
    if (!IMValidEntry(entry, directory, error)) return NO;
    NSString *name = entry[@"filename"], *target = enabled ? [name stringByDeletingPathExtension] : [name stringByAppendingString:@".disabled"];
    if ([entry[@"enabled"] boolValue] == enabled) return YES;
    IMLog(@"%@ %@ -> %@", enabled ? @"Enabling" : @"Disabling", name, target);
    BOOL moved = [NSFileManager.defaultManager moveItemAtPath:[directory stringByAppendingPathComponent:name] toPath:[directory stringByAppendingPathComponent:target] error:error];
    if (!moved) IMLog(@"ERROR could not rename %@: %@", name, error ? (*error).localizedDescription : @"");
    return moved;
}
+ (BOOL)removeEntry:(NSDictionary *)entry directory:(NSString *)directory error:(NSError **)error {
    if ([ModrinthModInstallation isInstalling]) { if (error) *error = IMError(@"mods.install.busy", nil); return NO; }
    if (!IMValidEntry(entry, directory, error)) return NO;
    IMLog(@"Removing %@", entry[@"filename"]);
    NSString *trash = [[IMRoot(directory) stringByAppendingPathComponent:@"trash"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:trash withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    BOOL removed = [NSFileManager.defaultManager moveItemAtPath:[directory stringByAppendingPathComponent:entry[@"filename"]] toPath:[trash stringByAppendingPathComponent:entry[@"filename"]] error:error];
    if (!removed) IMLog(@"ERROR could not remove %@: %@", entry[@"filename"], error ? (*error).localizedDescription : @"");
    if (removed && [@[@"amethyst-mcopt-default.jar", @"amethyst-mcopt-default.jar.disabled"] containsObject:entry[@"filename"]]) {
        [@{@"amethyst-mcopt-default.jar":@YES} writeToFile:[IMRoot(directory) stringByAppendingPathComponent:@"removed-default-mods.plist"] atomically:YES];
    }
    return removed;
}
+ (BOOL)recoverDirectory:(NSString *)directory error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [IMRoot(directory) stringByAppendingPathComponent:@"mod-batches"];
    for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *batch = [root stringByAppendingPathComponent:name];
        NSDictionary *journal = [NSDictionary dictionaryWithContentsOfFile:[batch stringByAppendingPathComponent:@"journal.plist"]];
        if (!journal) continue;
        if (![journal[@"complete"] boolValue]) {
            IMLog(@"RECOVERY an unfinished install was found (%@), putting the old files back", name);
            if (![journal[@"previous"] isKindOfClass:NSArray.class] || ![journal[@"targets"] isKindOfClass:NSArray.class]) { if (error) *error = IMError(@"mods.install.recovery_error", nil); return NO; }
            for (NSString *filename in [journal[@"targets"] arrayByAddingObjectsFromArray:journal[@"previous"]]) if (!IMName(filename)) { if (error) *error = IMError(@"mods.install.recovery_error", nil); return NO; }
            for (NSString *filename in journal[@"previous"]) {
                NSData *data = [NSData dataWithContentsOfFile:[[batch stringByAppendingPathComponent:@"backup"] stringByAppendingPathComponent:filename] options:0 error:error];
                if (!data || ![data writeToFile:[directory stringByAppendingPathComponent:filename] options:NSDataWritingAtomic error:error]) { IMLog(@"ERROR recovery could not restore %@: %@", filename, error ? (*error).localizedDescription : @""); return NO; }
            }
            for (NSString *filename in journal[@"targets"]) if (![journal[@"previous"] containsObject:filename]) {
                NSString *path = [directory stringByAppendingPathComponent:filename];
                if ([fm fileExistsAtPath:path] && ![fm removeItemAtPath:path error:error]) return NO;
            }
        }
        if (![fm removeItemAtPath:batch error:error]) return NO;
    }
    return YES;
}
+ (BOOL)commitPlan:(NSArray *)plan payloads:(NSDictionary *)payloads directory:(NSString *)directory error:(NSError **)error {
    IMLog(@"COMMIT start: %lu file(s) to write into %@", (unsigned long)plan.count, directory);
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error] || ![self recoverDirectory:directory error:error]) return NO;
    NSMutableOrderedSet *previous = [NSMutableOrderedSet new], *targets = [NSMutableOrderedSet new];
    for (NSDictionary *item in plan) {
        NSDictionary *file = [ModrinthModInstallation jarFileForVersion:item[@"version"]];
        NSString *target = [file[@"filename"] stringByAppendingString:[item[@"disabled"] boolValue] ? @".disabled" : @""];
        NSData *data = IMPayload(payloads[file[@"hashes"][@"sha1"]]);
        if (!IMName(target) || !data || data.length != [file[@"size"] unsignedLongLongValue] || ![IMHash(data) isEqual:[file[@"hashes"][@"sha1"] lowercaseString]] || [targets containsObject:target]) {
            IMLog(@"COMMIT rejected %@: valid name=%d, downloaded data present=%d, size ok=%d (got %lu, expected %llu), checksum ok=%d, duplicate name=%d", target, IMName(target), data != nil, data.length == [file[@"size"] unsignedLongLongValue], (unsigned long)data.length, [file[@"size"] unsignedLongLongValue], data ? [IMHash(data) isEqual:[file[@"hashes"][@"sha1"] lowercaseString]] : NO, [targets containsObject:target]);
            if (error) *error = IMError(@"mods.install.name_conflict", target); return NO;
        }
        [targets addObject:target];
        for (NSDictionary *entry in item[@"previous"]) { if (!IMValidEntry(entry, directory, error)) return NO; [previous addObject:entry[@"filename"]]; }
    }
    for (NSString *target in targets) if ([fm fileExistsAtPath:[directory stringByAppendingPathComponent:target]] && ![previous containsObject:target]) { IMLog(@"COMMIT rejected: a file named %@ already exists and is not one of the files being replaced", target); if (error) *error = IMError(@"mods.install.name_conflict", target); return NO; }
    NSString *batch = [[IMRoot(directory) stringByAppendingPathComponent:@"mod-batches"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *backup = [batch stringByAppendingPathComponent:@"backup"];
    if (![fm createDirectoryAtPath:backup withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    for (NSString *name in previous) if (![fm copyItemAtPath:[directory stringByAppendingPathComponent:name] toPath:[backup stringByAppendingPathComponent:name] error:error]) { IMLog(@"ERROR could not back up %@: %@", name, error ? (*error).localizedDescription : @""); [fm removeItemAtPath:batch error:nil]; return NO; }
    NSMutableDictionary *journal = [@{@"previous":previous.array, @"targets":targets.array, @"complete":@NO} mutableCopy];
    NSString *journalPath = [batch stringByAppendingPathComponent:@"journal.plist"];
    if (![journal writeToFile:journalPath atomically:YES]) { if (error) *error = IMError(@"mods.install.recovery_error", nil); [fm removeItemAtPath:batch error:nil]; return NO; }
    BOOL ok = YES;
    for (NSDictionary *item in plan) {
        NSDictionary *file = [ModrinthModInstallation jarFileForVersion:item[@"version"]];
        NSString *name = [file[@"filename"] stringByAppendingString:[item[@"disabled"] boolValue] ? @".disabled" : @""];
        if (![IMPayload(payloads[file[@"hashes"][@"sha1"]]) writeToFile:[directory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:error]) { IMLog(@"ERROR could not write %@: %@", name, error ? (*error).localizedDescription : @""); ok = NO; break; }
        IMLog(@"  wrote %@", name);
    }
    for (NSString *name in previous) if (ok && ![targets containsObject:name]) { ok = [fm removeItemAtPath:[directory stringByAppendingPathComponent:name] error:error]; if (ok) IMLog(@"  removed old file %@", name); else IMLog(@"ERROR could not remove old file %@", name); }
    if (ok) { journal[@"complete"] = @YES; ok = [journal writeToFile:journalPath atomically:YES]; }
    if (!ok && error && !*error) *error = IMError(@"mods.install.recovery_error", nil);
    NSError *recoveryError;
    if (![self recoverDirectory:directory error:&recoveryError]) { if (error) *error = recoveryError; return NO; }
    if (ok) {
        NSMutableDictionary *index = [[NSDictionary dictionaryWithContentsOfFile:[IMRoot(directory) stringByAppendingPathComponent:@"index.plist"]] mutableCopy] ?: [NSMutableDictionary new];
        for (NSDictionary *item in plan) { NSDictionary *file = [ModrinthModInstallation jarFileForVersion:item[@"version"]]; NSString *hash = file[@"hashes"][@"sha1"]; index[[item[@"provider"] isEqual:@"curseforge"] ? IMID(@"curseforge", hash) : hash] = item[@"version"]; }
        [[self persistentObject:index] writeToFile:[IMRoot(directory) stringByAppendingPathComponent:@"index.plist"] atomically:YES];
        IMLog(@"COMMIT finished successfully");
    } else IMLog(@"COMMIT failed and was rolled back");
    return ok;
}
@end
