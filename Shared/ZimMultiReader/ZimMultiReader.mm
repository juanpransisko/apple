//
//  ZimMultiReader.mm
//  Kiwix
//
//  Created by Chris Li on 8/17/17.
//  Copyright © 2017 Chris Li. All rights reserved.
//

#include <set>
#include <unordered_map>
#include "reader.h"
#include "searcher.h"
#import "ZimMultiReader.h"

@implementation ZimMultiReader

std::unordered_map<std::string, std::shared_ptr<kiwix::Reader>> readers;
std::unordered_map<std::string, std::shared_ptr<kiwix::Searcher>> externalSearchers;
kiwix::Searcher *searcher = new kiwix::Searcher;
std::vector<std::string> *searcherZimIDs = new std::vector<std::string>;
NSMutableDictionary *fileURLs = [[NSMutableDictionary alloc] init]; // [ID: FileURL]

#pragma mark - init

- (instancetype)init {
    self = [super init];
    if (self) {
        readers.reserve(20);
    }
    return self;
}

- (NSArray *)getReaderIdentifiers {
    return [fileURLs allKeys];
}

- (NSURL *)getReaderFileURL:(NSString *)identifier {
    return fileURLs[identifier];
}

#pragma mark - reader management

- (void)addReaderByURL:(NSURL *)url {
    try {
        // if url does not ends with "zim" or "zimaa", skip it
        NSString *pathExtension = [[url pathExtension] lowercaseString];
        if (![pathExtension isEqualToString:@"zim"] && ![pathExtension isEqualToString:@"zimaa"]) {
            return;
        }
        
        // if we have previously added this url, skip it
        if ([[fileURLs allKeysForObject:url] count] > 0) {
            return;
        }
        
#if TARGET_OS_MAC
        [url startAccessingSecurityScopedResource];
#endif
        
        // add the reader
        std::shared_ptr<kiwix::Reader> reader = std::make_shared<kiwix::Reader>([url fileSystemRepresentation]);
        std::string identifier = reader->getId();
        readers.insert(std::make_pair(identifier, reader));
        
        // check if there is an external idx directory
        NSURL *idxDirURL = [url URLByAppendingPathExtension:@"idx"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:[idxDirURL path]]) {
            kiwix::Searcher *searcher = new kiwix::Searcher([idxDirURL fileSystemRepresentation], reader.get(), identifier);
            externalSearchers.insert(std::make_pair(identifier, searcher));
        }
        
        NSString *identifierObjC = [NSString stringWithCString:identifier.c_str() encoding:NSUTF8StringEncoding];
        fileURLs[identifierObjC] = url;
    } catch (const std::exception &e) { }
}

- (void)removeReaderByID:(NSString *)bookID {
    std::string identifier = [bookID cStringUsingEncoding:NSUTF8StringEncoding];
    readers.erase(identifier);
    externalSearchers.erase(identifier);
#if TARGET_OS_MAC
    [fileURLs[bookID] stopAccessingSecurityScopedResource];
#endif
    [fileURLs removeObjectForKey:bookID];
}

- (void)removeStaleReaders {
    for (NSString *identifier in [fileURLs allKeys]) {
        NSURL *url = fileURLs[identifier];
        NSString *path = [url path];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [self removeReaderByID:identifier];
        }
    }
}

# pragma mark - check index

- (BOOL)hasEmbeddedIndex:(NSString *_Nonnull)zimFileID {
    auto found = readers.find([zimFileID cStringUsingEncoding:NSUTF8StringEncoding]);
    if (found == readers.end()) {
        return NO;
    } else {
        std::shared_ptr<kiwix::Reader> reader = found->second;
        return reader->hasFulltextIndex();
    }
}

- (BOOL)hasExternalIndex:(NSString *_Nonnull)zimFileID {
    auto found = externalSearchers.find([zimFileID cStringUsingEncoding:NSUTF8StringEncoding]);
    if (found == externalSearchers.end()) {
        return NO;
    } else {
        return YES;
    }
}

# pragma mark - get content

- (NSDictionary *)getContent:(NSString *)zimFileID contentURL:(NSString *)contentURL {
    auto found = readers.find([zimFileID cStringUsingEncoding:NSUTF8StringEncoding]);
    if (found == readers.end()) {
        return nil;
    } else {
        std::shared_ptr<kiwix::Reader> reader = found->second;
        
        std::string content;
        std::string title;
        unsigned int contentLength;
        std::string contentType;
        
        bool success = reader->getContentByUrl([contentURL cStringUsingEncoding:NSUTF8StringEncoding], content, title, contentLength, contentType);
        if (success) {
            NSData *data = [NSData dataWithBytes:content.data() length:contentLength];
            NSString *mime = [NSString stringWithUTF8String:contentType.c_str()];
            NSNumber *length = [NSNumber numberWithUnsignedInt:contentLength];
            return @{@"data": data, @"mime": mime, @"length": length};
        } else {
            return nil;
        }
    }
}

- (ZimMetaData *)getMetaData:(NSString *)zimFileID {
    NSURL *url = fileURLs[zimFileID];
    if (url == nil) {return nil;}
    return [[ZimMetaData alloc] initWithZimFileURL:url];
}

# pragma mark - URL handling

- (NSString *)getMainPageURL:(NSString *)bookID {
    auto found = readers.find([bookID cStringUsingEncoding:NSUTF8StringEncoding]);
    if (found == readers.end()) {
        return nil;
    } else {
        std::shared_ptr<kiwix::Reader> reader = found->second;
        std::string mainPageURLC = reader->getMainPageUrl();
        return [NSString stringWithCString:mainPageURLC.c_str() encoding:NSUTF8StringEncoding];
    }
}

# pragma mark - Search

- (void)startIndexSearch:(NSString *)searchText zimFileIDs:(NSSet *)zimFileIDs {
    for(auto iter: readers) {
        std::shared_ptr<kiwix::Reader> reader = iter.second;
        if (!reader->hasFulltextIndex()) {
            continue;
        }
        if (zimFileIDs == nil || [zimFileIDs containsObject:[NSString stringWithCString:iter.first.c_str() encoding:NSUTF8StringEncoding]]) {
            searcher->add_reader(reader.get(), iter.first);
            searcherZimIDs->push_back(iter.first);
        }
    }
    
    std::string searchTermC = [searchText cStringUsingEncoding:NSUTF8StringEncoding];
    int offset = 0;
    int limit = 20;
    searcher->search(searchTermC, offset, limit);
}

- (NSDictionary *)getNextIndexSearchResult {
    kiwix::Result *result = searcher->getNextResult();
    if (result != NULL) {
        NSString *identifier = [NSString stringWithCString:searcherZimIDs->at(result->get_readerIndex()).c_str() encoding:NSUTF8StringEncoding];
        NSString *title = [NSString stringWithCString:result->get_title().c_str() encoding:NSUTF8StringEncoding];
        NSString *path = [NSString stringWithCString:result->get_url().c_str() encoding:NSUTF8StringEncoding];
        NSNumber *probability = [[NSNumber alloc] initWithDouble:(double)result->get_score() / double(100)];
        NSString *snippet = [NSString stringWithCString:result->get_snippet().c_str() encoding:NSUTF8StringEncoding];
        // NSLog(@"id: %@, index: %d, path: %@", [identifier substringToIndex:8], result->get_readerIndex(), path);
        delete result;
        return @{@"id": identifier, @"title": title, @"path": path, @"probability": probability, @"snippet": snippet};
    } else {
        return nil;
    }
}

- (void)stopIndexSearch {
    searcher = new kiwix::Searcher;
    searcherZimIDs->clear();
}

- (NSArray *)getTitleSearchResults:(NSString *)searchText zimFileID:(NSString *)zimFileID count:(unsigned int)count {
    std::string searchTermC = [searchText cStringUsingEncoding:NSUTF8StringEncoding];
    NSMutableArray *suggestions = [[NSMutableArray alloc] init];
    
    auto found = readers.find([zimFileID cStringUsingEncoding:NSUTF8StringEncoding]);
    if (found == readers.end()) {
        return suggestions;
    } else {
        std::shared_ptr<kiwix::Reader> reader = found->second;
        reader->searchSuggestionsSmart(searchTermC, count);
        
        std::string titleC;
        std::string pathC;
        
        while (reader->getNextSuggestion(titleC, pathC)) {
            NSString *title = [NSString stringWithCString:titleC.c_str() encoding:NSUTF8StringEncoding];
            NSString *path = [NSString stringWithCString:pathC.c_str() encoding:NSUTF8StringEncoding];
            [suggestions addObject:@{@"id": zimFileID, @"title": title, @"path": path}];
        }
        return suggestions;
    }
}

- (NSSet *)getExternalIndexZimIDs {
    NSMutableSet *identifiers = [[NSMutableSet alloc] init];
    for(auto pair: externalSearchers) {
        NSString *identifier = [NSString stringWithCString:pair.first.c_str() encoding:NSUTF8StringEncoding];
        [identifiers addObject:identifier];
    }
    return identifiers;
}

- (NSArray *)getExternalIndexSearchResults: (NSString *)searchText zimFileID:(NSString *)zimFileID count:(unsigned int)count {
    std::string searchTermC = [searchText cStringUsingEncoding:NSUTF8StringEncoding];
    NSMutableArray *suggestions = [[NSMutableArray alloc] init];
    
    auto found = externalSearchers.find([zimFileID cStringUsingEncoding:NSUTF8StringEncoding]);
    if (found == externalSearchers.end()) {
        return suggestions;
    } else {
        std::shared_ptr<kiwix::Searcher> searcher = found->second;
        searcher->search(searchTermC, 0, count);
        
        kiwix::Result *result = searcher->getNextResult();
        while (result != NULL) {
            NSString *title = [NSString stringWithCString:result->get_title().c_str() encoding:NSUTF8StringEncoding];
            NSString *path = [NSString stringWithCString:result->get_url().c_str() encoding:NSUTF8StringEncoding];
            NSNumber *probability = [[NSNumber alloc] initWithDouble:(double)result->get_score() / double(100)];
            NSString *snippet = [NSString stringWithCString:result->get_snippet().c_str() encoding:NSUTF8StringEncoding];
            delete result;
            [suggestions addObject:@{@"id": zimFileID, @"title": title, @"path": path, @"probability": probability, @"snippet": snippet}];
        }
    }

    return suggestions;
}

@end
