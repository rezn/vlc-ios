//
//  VLCHTTPConnection.m
//  VLC for iOS
//
//  Created by Felix Paul Kühne on 05.11.13.
//  Copyright (c) 2013 VideoLAN. All rights reserved.
//
//  Refer to the COPYING file of the official project for license.
//

#import "VLCAppDelegate.h"
#import "VLCHTTPConnection.h"
#import "HTTPConnection.h"
#import "MultipartFormDataParser.h"
#import "HTTPMessage.h"
#import "HTTPDataResponse.h"
#import "HTTPFileResponse.h"
#import "MultipartMessageHeaderField.h"

@interface VLCHTTPConnection()
{
    MultipartFormDataParser *_parser;
    NSFileHandle *_storeFile;
    NSString *_filepath;
    NSString *_filename;
    UInt64 _contentLength;
    UInt64 _receivedContent;
}
@end

@implementation VLCHTTPConnection

- (BOOL)supportsMethod:(NSString *)method atPath:(NSString *)path
{
    // Add support for POST
    if ([method isEqualToString:@"POST"]) {
        if ([path isEqualToString:@"/upload.json"])
            return YES;
    }

    return [super supportsMethod:method atPath:path];
}

- (BOOL)expectsRequestBodyFromMethod:(NSString *)method atPath:(NSString *)path
{
    // Inform HTTP server that we expect a body to accompany a POST request
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/upload.json"]) {
        // here we need to make sure, boundary is set in header
        NSString* contentType = [request headerField:@"Content-Type"];
        NSUInteger paramsSeparator = [contentType rangeOfString:@";"].location;
        if (NSNotFound == paramsSeparator)
            return NO;

        if (paramsSeparator >= contentType.length - 1)
            return NO;

        NSString* type = [contentType substringToIndex:paramsSeparator];
        if (![type isEqualToString:@"multipart/form-data"]) {
            // we expect multipart/form-data content type
            return NO;
        }

        // enumerate all params in content-type, and find boundary there
        NSArray* params = [[contentType substringFromIndex:paramsSeparator + 1] componentsSeparatedByString:@";"];
        for (NSString* param in params) {
            paramsSeparator = [param rangeOfString:@"="].location;
            if ((NSNotFound == paramsSeparator) || paramsSeparator >= param.length - 1)
                continue;

            NSString* paramName = [param substringWithRange:NSMakeRange(1, paramsSeparator-1)];
            NSString* paramValue = [param substringFromIndex:paramsSeparator+1];

            if ([paramName isEqualToString: @"boundary"])
                // let's separate the boundary from content-type, to make it more handy to handle
                [request setHeaderField:@"boundary" value:paramValue];
        }
        // check if boundary specified
        if (nil == [request headerField:@"boundary"])
            return NO;

        return YES;
    }
    return [super expectsRequestBodyFromMethod:method atPath:path];
}

- (NSObject<HTTPResponse> *)httpResponseForMethod:(NSString *)method URI:(NSString *)path
{
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/upload.json"]) {
        return [[HTTPDataResponse alloc] initWithData:[@"\"OK\"" dataUsingEncoding:NSUTF8StringEncoding]];
    }
    if ([method isEqualToString:@"GET"] && [path hasPrefix:@"/upload/"]) {
        // let download the uploaded files
        return [[HTTPFileResponse alloc] initWithFilePath: [[config documentRoot] stringByAppendingString:path] forConnection:self];
    }

    return [super httpResponseForMethod:method URI:path];
}

- (void)prepareForBodyWithSize:(UInt64)contentLength
{
    // set up mime parser
    NSString* boundary = [request headerField:@"boundary"];
    _parser = [[MultipartFormDataParser alloc] initWithBoundary:boundary formEncoding:NSUTF8StringEncoding];
    _parser.delegate = self;

    APLog(@"expecting file of size %lli kB", contentLength / 1024);
    _contentLength = contentLength;
}

- (void)processBodyData:(NSData *)postDataChunk
{
    /* append data to the parser. It will invoke callbacks to let us handle
     * parsed data. */
    [_parser appendData:postDataChunk];

    _receivedContent += postDataChunk.length;

    APLog(@"received %lli kB (%lli %%)", _receivedContent / 1024, ((_receivedContent * 100) / _contentLength));
}

//-----------------------------------------------------------------
#pragma mark multipart form data parser delegate


- (void)processStartOfPartWithHeader:(MultipartMessageHeader*) header
{
    /* in this sample, we are not interested in parts, other then file parts.
     * check content disposition to find out filename */

    MultipartMessageHeaderField* disposition = (header.fields)[@"Content-Disposition"];
    NSString* filename = [(disposition.params)[@"filename"] lastPathComponent];

    if ((nil == filename) || [filename isEqualToString: @""]) {
        // it's either not a file part, or
        // an empty form sent. we won't handle it.
        return;
    }
    _filename = filename;

    // create the path where to store the media temporarily
    NSArray *searchPaths = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES);
    NSString* uploadDirPath = searchPaths[0];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    BOOL isDir = YES;
    if (![fileManager fileExistsAtPath:uploadDirPath isDirectory:&isDir ]) {
        [fileManager createDirectoryAtPath:uploadDirPath withIntermediateDirectories:YES attributes:nil error:nil];
    }

    _filepath = [uploadDirPath stringByAppendingPathComponent: filename];

    APLog(@"Saving file to %@", _filepath);
    if (![fileManager createDirectoryAtPath:uploadDirPath withIntermediateDirectories:true attributes:nil error:nil])
        APLog(@"Could not create directory at path: %@", _filepath);

    if (![fileManager createFileAtPath:_filepath contents:nil attributes:nil])
        APLog(@"Could not create file at path: %@", _filepath);

    _storeFile = [NSFileHandle fileHandleForWritingAtPath:_filepath];
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    [(VLCAppDelegate*)[UIApplication sharedApplication].delegate disableIdleTimer];
}

- (void)processContent:(NSData*)data WithHeader:(MultipartMessageHeader*) header
{
    // here we just write the output from parser to the file.
    if (_storeFile)
        [_storeFile writeData:data];
}

- (void)processEndOfPartWithHeader:(MultipartMessageHeader*)header
{
    // as the file part is over, we close the file.
    APLog(@"closing file");
    [_storeFile closeFile];
    _storeFile = nil;

    NSArray *searchPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *libraryPath = searchPaths[0];
    NSString *finalFilePath = [libraryPath stringByAppendingPathComponent:_filename];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if ([fileManager fileExistsAtPath:finalFilePath]) {
        /* we don't want to over-write existing files, so add an integer to the file name */
        NSString *potentialFilename;
        NSString *fileExtension = [_filename pathExtension];
        NSString *rawFileName = [_filename stringByDeletingPathExtension];
        for (NSUInteger x = 1; x < 100; x++) {
            potentialFilename = [NSString stringWithFormat:@"%@ %i.%@", rawFileName, x, fileExtension];
            if (![[NSFileManager defaultManager] fileExistsAtPath:[libraryPath stringByAppendingPathComponent:potentialFilename]])
                break;
        }
        finalFilePath = [libraryPath stringByAppendingPathComponent:potentialFilename];
    }

    NSError *error;
    [fileManager moveItemAtPath:_filepath toPath:finalFilePath error:&error];
    if (error) {
        APLog(@"Moving received media %@ to library folder failed (%i), deleting", _filename, error.code);
        [fileManager removeItemAtPath:_filepath error:nil];
    }

    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    [(VLCAppDelegate*)[UIApplication sharedApplication].delegate activateIdleTimer];

    /* update media library when file upload was completed */
    VLCAppDelegate* appDelegate = [UIApplication sharedApplication].delegate;
    [appDelegate updateMediaList];
}

- (void)die
{
    if (_storeFile) {
        _storeFile = nil;
        [[NSFileManager defaultManager] removeItemAtPath:_filepath error:nil];
        [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
        [(VLCAppDelegate*)[UIApplication sharedApplication].delegate activateIdleTimer];
    }

    [super die];
}

@end
