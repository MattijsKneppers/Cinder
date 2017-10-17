/*
 Copyright (c) 2014, The Cinder Project, All rights reserved.
 
 This code is intended for use with the Cinder C++ library: http://libcinder.org
 
 Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 the following conditions are met:
 
 * Redistributions of source code must retain the above copyright notice, this list of conditions and
 the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and
 the following disclaimer in the documentation and/or other materials provided with the distribution.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
 WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
 ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
 */

#include "cinder/Cinder.h"
#include <AvailabilityMacros.h>

#define VIDEO_ONLY true

// This path is used on iOS or Mac OS X 10.8+
#if defined( CINDER_COCOA_TOUCH ) || ( defined( CINDER_MAC ) && ( MAC_OS_X_VERSION_MIN_REQUIRED >= 1080 ) )

#include "cinder/gl/platform.h"
#include "cinder/app/AppBase.h"
#include "cinder/app/RendererGl.h"
#include "cinder/Url.h"

#if defined( CINDER_COCOA )
	#import <AVFoundation/AVFoundation.h>
	#if defined( CINDER_COCOA_TOUCH )
		#import <CoreVideo/CoreVideo.h>
	#else
		#import <CoreVideo/CVDisplayLink.h>
	#endif
#endif

#include "cinder/qtime/QuickTimeImplAvf.h"
#include "cinder/qtime/AvfUtils.h"

#ifdef USE_HAP
	#import <HapInAVFoundation/HapInAVFoundation.h>
	#import "../../src/hapinavf/HapInAVF Test App/HapPixelBufferTexture.h"
	#include "cinder/gl/GlslProg.h"
#endif

////////////////////////////////////////////////////////////////////////
//
// TODO: use global time from the system clock
// TODO: setup CADisplayLink for iOS, remove CVDisplayLink callback on OSX
// TODO: test operations for thread-safety -- add/remove locks as necessary
//
////////////////////////////////////////////////////////////////////////

static void* AVPlayerItemStatusContext = &AVPlayerItemStatusContext;

@interface MovieDelegate : NSObject<AVPlayerItemOutputPullDelegate> {
	cinder::qtime::MovieResponder* responder;
}

- (id)initWithResponder:(cinder::qtime::MovieResponder*)player;
- (void)playerReady;
- (void)playerItemDidReachEndCallback;
- (void)playerItemDidNotReachEndCallback;
- (void)playerItemTimeJumpedCallback;
#if defined( CINDER_COCOA_TOUCH )
- (void)displayLinkCallback:(CADisplayLink*)sender;
#elif defined( CINDER_COCOA )
- (void)displayLinkCallback:(CVDisplayLinkRef*)sender;
#endif
- (void)outputSequenceWasFlushed:(AVPlayerItemOutput *)output;

@end


@implementation MovieDelegate

- (void)dealloc
{
	[super dealloc];
}

- (id)init
{
	self = [super init];
	self->responder = nil;
	return self;
}

- (id)initWithResponder:(cinder::qtime::MovieResponder*)player
{
	self = [super init];
	self->responder = player;
	return self;
}

- (void)playerReady
{
	self->responder->playerReadyCallback();
}

- (void)playerItemDidReachEndCallback
{
	self->responder->playerItemDidReachEndCallback();
}

- (void)playerItemDidNotReachEndCallback
{
	self->responder->playerItemDidNotReachEndCallback();
}

- (void)playerItemTimeJumpedCallback
{
	self->responder->playerItemTimeJumpedCallback();
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if (context == AVPlayerItemStatusContext) {
		AVPlayerItem* player_item = (AVPlayerItem*)object;
		AVPlayerItemStatus status = [player_item status];
		switch (status) {
			case AVPlayerItemStatusUnknown:
//				ci::app::console() << "AVPlayerItemStatusUnknown" << std::endl;
				break;
			case AVPlayerItemStatusReadyToPlay:
//				ci::app::console() << "AVPlayerItemStatusReadyToPlay" << std::endl;
				[self playerReady];
				break;
			case AVPlayerItemStatusFailed:
//				ci::app::console() << "AVPlayerItemStatusFailed" << std::endl;
				break;
		}
	}
	else {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

#pragma mark - CADisplayLink Callback

#if defined( CINDER_COCOA_TOUCH )
- (void)displayLinkCallback:(CADisplayLink*)sender
#elif defined( CINDER_COCOA )
- (void)displayLinkCallback:(CVDisplayLinkRef*)sender
#endif
{
	ci::app::console() << "displayLinkCallback" << std::endl;
	
	/*
	 CMTime outputItemTime = kCMTimeInvalid;
	 
	 // Calculate the nextVsync time which is when the screen will be refreshed next.
	 CFTimeInterval nextVSync = ([sender timestamp] + [sender duration]);
	 
	 outputItemTime = [[self videoOutput] itemTimeForHostTime:nextVSync];
	 
	 if ([[self videoOutput] hasNewPixelBufferForItemTime:outputItemTime]) {
	 CVPixelBufferRef pixelBuffer = NULL;
	 pixelBuffer = [[self videoOutput] copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
	 
	 [[self playerView] displayPixelBuffer:pixelBuffer];
	 }
	 */
}

- (void)outputSequenceWasFlushed:(AVPlayerItemOutput *)output
{
	self->responder->outputSequenceWasFlushedCallback(output);
}

@end


// this has a conflict with Boost 1.53, so instead just declare the symbol extern
namespace cinder {
	extern void sleep( float milliseconds );
}

namespace cinder { namespace qtime {
	
MovieBase::MovieBase()
:	mPlayer( nil ),
	mPlayerItem( nil ),
	mAsset( nil ),
	mPlayerVideoOutput( nil ),
#ifdef USE_HAP
	mPlayerHapOutput(nil),
#endif
	mPlayerDelegate( nil ),
	mResponder( nullptr ),
	mAssetLoaded( false )
{
	init();
}

MovieBase::~MovieBase()
{
//	app::console() << "destructing movie" << std::endl;
	// remove all observers
	removeObservers();
	
	// release resources for AVF objects.
	if( mPlayer ) {
		[mPlayer cancelPendingPrerolls];
		[mPlayer release];
	}
	
	if( mAsset ) {
		[mAsset cancelLoading];
		[mAsset release];
	}

	if( mPlayerVideoOutput ) {
		[mPlayerVideoOutput setDelegate:nil queue:nil];
		[mPlayerVideoOutput release];
	}
}
	
float MovieBase::getPixelAspectRatio() const
{
	float pixelAspectRatio = 1.0;
	
	if( ! mAsset )
		return pixelAspectRatio;
	
	NSArray* video_tracks = [mAsset tracksWithMediaType:AVMediaTypeVideo];
	if( video_tracks ) {
		CMFormatDescriptionRef format_desc = NULL;
		NSArray* descriptions_arr = [[video_tracks firstObject] formatDescriptions];
		if ([descriptions_arr count] > 0)
			format_desc = (CMFormatDescriptionRef)[descriptions_arr firstObject];
		
		CGSize size;
		if (format_desc)
			size = CMVideoFormatDescriptionGetPresentationDimensions(format_desc, false, false);
		else
			size = [[video_tracks firstObject] naturalSize];
		
		CFDictionaryRef pixelAspectRatioDict = (CFDictionaryRef) CMFormatDescriptionGetExtension(format_desc, kCMFormatDescriptionExtension_PixelAspectRatio);
		if (pixelAspectRatioDict) {
			CFNumberRef horizontal = (CFNumberRef) CFDictionaryGetValue(pixelAspectRatioDict, kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing);//, AVVideoPixelAspectRatioHorizontalSpacingKey,
			CFNumberRef vertical = (CFNumberRef) CFDictionaryGetValue(pixelAspectRatioDict, kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing);//, AVVideoPixelAspectRatioVerticalSpacingKey,
			float x_value, y_value;
			if (horizontal && vertical) {
				if (CFNumberGetValue(horizontal, kCFNumberFloat32Type, &x_value) &&
					CFNumberGetValue(vertical, kCFNumberFloat32Type, &y_value))
				{
					pixelAspectRatio = x_value / y_value;
				}
			}
		}
	}
	
	return pixelAspectRatio;
}

bool MovieBase::checkPlaythroughOk()
{
#ifdef USE_HAP
	if (mHapLoaded) return true;
#endif
	mPlayThroughOk = [mPlayerItem isPlaybackLikelyToKeepUp];
	
	return mPlayThroughOk;
}

int32_t MovieBase::getNumFrames()
{
	if( mFrameCount <= 0 )
		mFrameCount = countFrames();
	
	return mFrameCount;
}

bool MovieBase::checkNewFrame()
{
//	app::console() << "has new frame? at " << CMTimeGetSeconds([mPlayer currentTime]) << std::endl;
	if( ! mPlayer || ! mPlayerVideoOutput )
		return false;
	
	if( mPlayerVideoOutput )
//#ifdef USE_HAP
//	{
//		return true;
//	}
//#else
		return [mPlayerVideoOutput hasNewPixelBufferForItemTime:[mPlayer currentTime]];
//#endif
	else
		return false;
}

float MovieBase::getCurrentTime() const
{
	if( ! mPlayer )
		return -1.0f;
	
	return CMTimeGetSeconds([mPlayer currentTime]);
}

bool MovieBase::seekToTime( float seconds )
{
	if( ! mPlayer || ! mPlayerItem || !mPlayable || mPlayer.status != AVPlayerStatusReadyToPlay) {
		return false;
	}
	
//	app::console() << " seeking to time " << seconds << ", using timescale " << [mPlayer currentTime].timescale << std::endl;
	CMTime seek_time = CMTimeMakeWithSeconds(seconds, [mAsset duration].timescale);
	[mPlayer seekToTime:seek_time toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
		mSignalSeekDone.emit(finished);
	}];
	return true;
}

void MovieBase::seekToFrame( int frame )
{
	if( ! mPlayer || ! mPlayerItem || !mPlayable || mPlayer.status != AVPlayerStatusReadyToPlay ) {
		return;
	}
	
	CMTime oneFrame = CMTimeMakeWithSeconds(1.0 / mFrameRate, [mAsset duration].timescale);
	CMTime startTime = kCMTimeZero;
	CMTime addedFrame = CMTimeMultiply(oneFrame, frame);
	CMTime added = CMTimeAdd(startTime, addedFrame);
	
//		app::console() << " seeking to frame " << frame << ", using timescale " << [mPlayer currentTime].timescale << std::endl;
	[mPlayer seekToTime:added toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
		mSignalSeekDone.emit(finished);
	}];
}

void MovieBase::seekToStart()
{
	if( ! mPlayer )
		return;
	
	[mPlayer seekToTime:kCMTimeZero];
}

void MovieBase::seekToEnd()
{
	if( ! mPlayer || ! mPlayerItem )
		return;
	
	if( mPlayingForward ) {
		[mPlayer seekToTime:[mPlayerItem forwardPlaybackEndTime]];
	}
	else {
		[mPlayer seekToTime:[mPlayerItem reversePlaybackEndTime]];
	}
}

void MovieBase::setActiveSegment( float startTime, float duration )
{
	if( ! mPlayer || ! mPlayerItem )
		return;
	
	int32_t scale = [mPlayer currentTime].timescale;
	CMTime cm_start = CMTimeMakeWithSeconds(startTime, scale);
	CMTime cm_duration = CMTimeMakeWithSeconds(startTime + duration, scale);
	
	if (mPlayingForward) {
		[mPlayer seekToTime:cm_start];
		[mPlayerItem setForwardPlaybackEndTime:cm_duration];
	}
	else {
		[mPlayer seekToTime:cm_duration];
		[mPlayerItem setReversePlaybackEndTime:cm_start];
	}
}

void MovieBase::resetActiveSegment()
{
	if( ! mPlayer || ! mPlayerItem )
		return;
	
	if (mPlayingForward) {
		[mPlayer seekToTime:kCMTimeZero];
		[mPlayerItem setForwardPlaybackEndTime:[mPlayerItem duration]];
	}
	else {
		[mPlayer seekToTime:[mPlayerItem duration]];
		[mPlayerItem setReversePlaybackEndTime:kCMTimeZero];
	}
}

void MovieBase::setLoop( bool loop, bool palindrome )
{
	mLoop = loop;
	mPalindrome = (loop? palindrome: false);
}
	
bool MovieBase::getLoop() {
	return mLoop;
}
	
bool MovieBase::stepForward()
{
	if( ! mPlayerItem )
		return false;
	
	bool can_step_forwards = [mPlayerItem canStepForward];
	if( can_step_forwards ) {
		[mPlayerItem stepByCount:1];
	}
	
	return can_step_forwards;
}

bool MovieBase::stepBackward()
{
	if( ! mPlayerItem)
		return false;
	
	bool can_step_backwards = [mPlayerItem canStepBackward];
	
	if (can_step_backwards) {
		[mPlayerItem stepByCount:-1];
	}
	
	return can_step_backwards;
}

bool MovieBase::prerollAtRate( float rate )
{
	if( ! mPlayer || ! mPlayerItem || !mPlayable || mPlayer.status != AVPlayerStatusReadyToPlay) {
		return false;
	}
	
	[mPlayer prerollAtRate:rate completionHandler:^(BOOL finished) {
		mSignalPrerollDone.emit(finished);
	}];
	return true;
}
	
bool MovieBase::setRate( float rate )
{
	if( ! mPlayer || ! mPlayerItem )
		return false;
	
	bool success;
	
	if( rate < -1.0f )
		success = [mPlayerItem canPlayFastReverse];
	else if( rate < 0.0f )
		success = [mPlayerItem canPlaySlowReverse];
	else if( rate > 1.0f )
		success = [mPlayerItem canPlayFastForward];
	else
		success = [mPlayerItem canPlaySlowForward];
	
	[mPlayer setRate:rate];
	
	return success;
}

void MovieBase::setVolume( float volume )
{
	if( ! mPlayer )
		return;
	
#if defined( CINDER_COCOA_TOUCH )
	NSArray* audioTracks = [mAsset tracksWithMediaType:AVMediaTypeAudio];
	NSMutableArray* allAudioParams = [NSMutableArray array];
	for( AVAssetTrack *track in audioTracks ) {
		AVMutableAudioMixInputParameters* audioInputParams =[AVMutableAudioMixInputParameters audioMixInputParameters];
		[audioInputParams setVolume:volume atTime:kCMTimeZero];
		[audioInputParams setTrackID:[track trackID]];
		[allAudioParams addObject:audioInputParams];
	}
	AVMutableAudioMix* volumeMix = [AVMutableAudioMix audioMix];
	[volumeMix setInputParameters:allAudioParams];
	[mPlayerItem setAudioMix:volumeMix];
	
#elif defined( CINDER_COCOA )
	[mPlayer setVolume:volume];
	
#endif
}

float MovieBase::getVolume() const
{
	if (!mPlayer) return -1;
	
#if defined( CINDER_COCOA_TOUCH )
	AVMutableAudioMix* mix = (AVMutableAudioMix*) [mPlayerItem audioMix];
	NSArray* inputParams = [mix inputParameters];
	float startVolume, endVolume;
	bool success = false;
	for( AVAudioMixInputParameters* param in inputParams )
		success = [param getVolumeRampForTime:[mPlayerItem currentTime] startVolume:&startVolume endVolume:&endVolume timeRange:NULL] || success;

	if( ! success )
		return -1;
	else
		return endVolume;
	
#elif defined( CINDER_COCOA )
	return [mPlayer volume];
#endif
}

bool MovieBase::isPlaying() const
{
	if( ! mPlayer )
		return false;
	
	return [mPlayer rate] != 0;
}

bool MovieBase::isDone() const
{
	if( ! mPlayer )
		return false;
	
	CMTime current_time = [mPlayerItem currentTime];
	CMTime end_time = mPlayingForward ? [mPlayerItem duration] : kCMTimeZero;
	return ::CMTimeCompare( current_time, end_time ) >= 0;
}

void MovieBase::play(bool toggle)
{
	if( ! mPlayer ) {
		mPlaying = true;
		return;
	}
	
	if( toggle ) {
		isPlaying()? [mPlayer pause]: [mPlayer play];
	}
	else {
		[mPlayer play];
	}
}

void MovieBase::stop()
{
	mPlaying = false;
	
	if( ! mPlayer )
		return;
	
	[mPlayer pause];
}

void MovieBase::init()
{
	mHasAudio = mHasVideo = false;
	mPlayThroughOk = mPlayable = mProtected = false;
	mPlaying = false;
	mPlayingForward = true;
	mLoop = mPalindrome = false;
	mFrameRate = -1;
	mWidth = -1;
	mHeight = -1;
	mDuration = -1;
	mFrameCount = -1;
	videoOnly = false;
}
	
void MovieBase::initFromUrl( const Url& url, bool _videoOnly )
{
	videoOnly = _videoOnly;
	seamlessSegments = false;

	NSURL* asset_url = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
	if( ! asset_url )
		throw AvfUrlInvalidExc();
	
	// Create the AVAsset
	NSDictionary* asset_options = @{(id)AVURLAssetPreferPreciseDurationAndTimingKey: @(YES)};
	mAsset = [[AVURLAsset alloc] initWithURL:asset_url options:asset_options];
	
	mResponder = new MovieResponder( this );
	mPlayerDelegate = [[MovieDelegate alloc] initWithResponder:mResponder];
	
	loadAsset();
}

void MovieBase::initFromPath( const fs::path& filePath, bool _videoOnly )
{
	videoOnly = _videoOnly;
	seamlessSegments = false;
	
	NSURL* asset_url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filePath.c_str()]];
	if( ! asset_url )
		throw AvfPathInvalidExc();
	
	// Create the AVAsset
	NSDictionary* asset_options = @{(id)AVURLAssetPreferPreciseDurationAndTimingKey: @(YES)};
	mAsset = [[AVURLAsset alloc] initWithURL:asset_url options:asset_options];
	
	mResponder = new MovieResponder(this);
	mPlayerDelegate = [[MovieDelegate alloc] initWithResponder:mResponder];
	
	loadAsset();
	
	// spin-wait until asset loading is completed
	while( ! mAssetLoaded ) {
	}
}
	
	void MovieBase::initFromPath( const fs::path& filePath, std::vector<std::pair<float, float>> _segments, bool _videoOnly )
{
	videoOnly = _videoOnly;
	seamlessSegments = true;
	segments = _segments;
	
	NSURL* asset_url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filePath.c_str()]];
	if( ! asset_url )
		throw AvfPathInvalidExc();
	
	// Create the AVAsset
	NSDictionary* asset_options = @{(id)AVURLAssetPreferPreciseDurationAndTimingKey: @(YES)};
	mAsset = [[AVURLAsset alloc] initWithURL:asset_url options:asset_options];
	
	mResponder = new MovieResponder(this);
	mPlayerDelegate = [[MovieDelegate alloc] initWithResponder:mResponder];
	
	loadAsset();
	
	// spin-wait until asset loading is completed
	while( ! mAssetLoaded ) {
	}
}

void MovieBase::initFromLoader( const MovieLoader& loader, bool _videoOnly )
{
	videoOnly = _videoOnly;
	if( ! loader.ownsMovie() )
		return;
	
	loader.waitForLoaded();
	mPlayer = loader.transferMovieHandle();
	mPlayerItem = [mPlayer currentItem];
	mAsset = reinterpret_cast<AVURLAsset*>([mPlayerItem asset]);
	
	mResponder = new MovieResponder( this );
	mPlayerDelegate = [[MovieDelegate alloc] initWithResponder:mResponder];

	// process asset and prepare for playback...
	processAssetTracks( mAsset );
	
	// collect asset information
	mLoaded = true;
	mDuration = (float) CMTimeGetSeconds([mAsset duration]);
	mPlayable = [mAsset isPlayable];
	mProtected = [mAsset hasProtectedContent];
	mPlayThroughOk = [mPlayerItem isPlaybackLikelyToKeepUp];
	
	// setup PlayerItemVideoOutput --from which we will obtain direct texture access
	createPlayerItemOutput( mPlayerItem );
	
	// without this the player continues to move the playhead past the asset duration time...
	[mPlayer setActionAtItemEnd:AVPlayerActionAtItemEndPause];
	
	addObservers();
	
	allocateVisualContext();
}

NSMutableArray *supportedFormats = [NSMutableArray arrayWithObjects:@"ap4h",@"jpeg", @"Hap5", @"HapY", @"avc1",nil];
	
bool MovieBase::isFormatSupported(AVAsset* asset) {
	NSString* format = getVideoFormat(asset);
	return [supportedFormats containsObject: format];
}
	
void MovieBase::loadAsset()
{
//	app::console() << "loading asset. video only is " << (videoOnly ? "on" : "off")  << ", seamless segments is " << (seamlessSegments ? "on" : "off") << std::endl;
	
	NSArray* keyArray = [NSArray arrayWithObjects:@"tracks", @"duration", @"playable", @"hasProtectedContent", nil];
	[mAsset loadValuesAsynchronouslyForKeys:keyArray completionHandler:^{
		
		NSString* format = getVideoFormat(mAsset);
//		NSLog(@"format %@", getVideoFormat(mAsset)); // TODO: check if this format is supported
		

		if (videoOnly) {
			NSArray<AVAssetTrack *> *videoTracks = [mAsset tracksWithMediaType:AVMediaTypeVideo];
			if (videoTracks.count > 0) {
				AVAssetTrack *videoTrack = [videoTracks objectAtIndex:0];
				
#ifdef USE_HAP
				if(!([format rangeOfString:@"Hap"].location == NSNotFound)) {
					seamlessSegments = false;
					mHapLoaded = true;
					/*if([format compare:@"HapY"] == NSOrderedSame) {
						mHapBitmapType = JIT_BITMAP_TYPE_YCoCg_DXT5;
					}
					else {
						mHapBitmapType = 0;
					}*/
				}
#endif
				
				CMTime videoDuration = mAsset.duration;
				
				AVMutableComposition *mutableComposition = [AVMutableComposition composition];
				AVMutableCompositionTrack *mutableCompositionVideoTrack = [mutableComposition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];

				bool foundError = false;
				if (seamlessSegments) {
					
					float offset = 0;
					for (auto segment : segments) {
						CMTime segmentStartTime = CMTimeMakeWithSeconds(segment.first, videoDuration.timescale);
						CMTime segmentDuration = CMTimeMakeWithSeconds(segment.second - segment.first, videoDuration.timescale);
						
						CMTime offsetTime = CMTimeMakeWithSeconds(offset, videoDuration.timescale);

						// Then add segments from loop start to loop end.
	//					app::console() << "Adding segment from " << segment.first << " of duration " << (segment.second - segment.first) << " starting at " << offset << std::endl;
						NSError *err;
						bool success = [mutableCompositionVideoTrack insertTimeRange:CMTimeRangeMake(segmentStartTime,segmentDuration) ofTrack:videoTrack atTime:offsetTime error:&err];
						if (!success) {
							app::console() << "Adding segment of time failed: " << err << std::endl;
							foundError = true;
						}
						
	//					app::console() << "Duration now: " << CMTimeGetSeconds([mutableComposition duration]) << std::endl;
						
						offset += segment.second - segment.first;
					}
					// Each loop takes approximately 0.25 KB of RAM.
				}
				else {
					// add full video track once.
					NSError *err;
					bool success = [mutableCompositionVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero,videoDuration) ofTrack:videoTrack atTime:kCMTimeZero error:&err];
					if (!success) {
						app::console() << "Adding video track failed: " << err << std::endl;
						foundError = true;
					}
				}
				AVComposition* immutableSnapshotOfMyComposition = [mutableComposition copy];
				mPlayerItem = [AVPlayerItem playerItemWithAsset:immutableSnapshotOfMyComposition];
				mLoaded = !foundError;
			}
			else {
				app::console() << "Loading video failed: no video track available" << std::endl;
				mLoaded = false;
			}
		}
		else {
			mPlayerItem = [AVPlayerItem playerItemWithAsset:mAsset];
			mLoaded = true;
		}
		
		if (mLoaded) {
			// Create a new AVPlayerItem
			mPlayer = [[AVPlayer alloc] init];
			if (videoOnly) mPlayer.volume = 0;
			
			NSError* error = nil;
			AVKeyValueStatus status = [mAsset statusOfValueForKey:@"tracks" error:&error];
			if( status == AVKeyValueStatusLoaded && ! error ) {
				processAssetTracks( mAsset );
			}
			
			error = nil;
			status = [mAsset statusOfValueForKey:@"duration" error:&error];
			if( status == AVKeyValueStatusLoaded && ! error ) {
				mDuration = (float) CMTimeGetSeconds([mAsset duration]);
			}
			
			error = nil;
			status = [mAsset statusOfValueForKey:@"playable" error:&error];
			if( status == AVKeyValueStatusLoaded && ! error ) {
				mPlayable = [mAsset isPlayable];
			}
			
			error = nil;
			status = [mAsset statusOfValueForKey:@"hasProtectedContent" error:&error];
			if ( status == AVKeyValueStatusLoaded && ! error ) {
				mProtected = [mAsset hasProtectedContent];
			}
			
			[mPlayer replaceCurrentItemWithPlayerItem:mPlayerItem];
			
			// setup PlayerItemVideoOutput --from which we will obtain direct texture access
			createPlayerItemOutput( mPlayerItem );
			
			// without this the player continues to move the playhead past the asset duration time...
			[mPlayer setActionAtItemEnd:AVPlayerActionAtItemEndPause];
			
			addObservers();
			
			allocateVisualContext();
		}
	
		mAssetLoaded = true;
	}];
}

ci::gl::GlslProgRef loadShaderProg(std::string vertexName, std::string fragmentName) {
	try {
		return gl::GlslProg::create(ci::app::loadResource(vertexName), ci::app::loadResource(fragmentName));
	}
	catch( gl::GlslProgCompileExc ex ) {
		app::console() << "Error compiling shader: " << ex.what();
		return NULL;
	}
}
	
std::string passTextureVertexShader() {
	std::string s =
	"	#version 150\n"
	
	"	uniform mat4	ciModelViewProjection;\n"
	"	in vec4			ciPosition;\n"
	"	in vec2			ciTexCoord0;\n"
	
	"	out vec2        texCoord0;\n"
	
	"	void main()\n"
	"	{\n"
	"		texCoord0 = ciTexCoord0;\n"
		
	"		gl_Position = ciModelViewProjection * ciPosition;\n"
	"	}\n";
	
	return s;
}
	
std::string passTextureFragmentShader() {
	std::string s =
	
	"	#version 150\n"
	
	"	uniform sampler2D tex0;\n"
	
	"	in vec2	texCoord0;\n"
	"	out vec4 outColor;\n"
	
	"	void main() {\n"
	"		outColor = texture(tex0, texCoord0);\n"
	"	}\n";

	return s;
}
	
std::string hapCoCgYToRGBAShader()
{
	std::string s =
	"	#version 150\n"

	"	uniform sampler2D cocgsy_src;\n"
	
	"	in vec2	texCoord0;\n"
	"	out vec4 outColor;\n"
	
	"	const vec4 offsets = vec4(-0.50196078431373, -0.50196078431373, 0.0, 0.0);\n"
	
	"	void main()\n"
	"	{\n"
	"		vec4 CoCgSY = texture(cocgsy_src, texCoord0);\n"
		
	"		CoCgSY += offsets;\n"
		
	"		float scale = ( CoCgSY.z * ( 255.0 / 8.0 ) ) + 1.0;\n"
		
	"		float Co = CoCgSY.x / scale;\n"
	"		float Cg = CoCgSY.y / scale;\n"
	"		float Y = CoCgSY.w;\n"
		
	"		vec4 rgba = vec4(Y + Co - Cg, Y + Cg, Y - Co - Cg, 1.0);\n"
		
	"		outColor = rgba;\n"
	"	}\n";
	return s;
}

void MovieBase::updateFrame()
{
	if( mPlayerVideoOutput && mPlayerItem ) {
		CMTime vTime = [mPlayer currentTime];
#ifdef USE_HAP
		if(!mHapTexture) {
			mHapTexture = [[HapPixelBufferTexture alloc] initWithContext:CGLGetCurrentContext()];
		}

		if(!mHapTexture || !mPlayerHapOutput)
			return;
		
		HapDecoderFrame	*dxtFrame = [mPlayerHapOutput allocFrameClosestToTime:vTime];
		if (dxtFrame!=nil)	{
			NSSize					imgSize = [dxtFrame imgSize];
			NSSize					dxtImgSize = [dxtFrame dxtImgSize];
			NSSize					dxtTexSize;
			
			// On NVIDIA hardware there is a massive slowdown if DXT textures aren't POT-dimensioned, so we use POT-dimensioned backing
			//	NOTE: NEEDS TESTING. this used to be the case- but this API is only available on 10.10+, so this may have been fixed.
			int						tmpInt;
			tmpInt = 1;
			while (tmpInt < dxtImgSize.width)
				tmpInt = tmpInt<<1;
			dxtTexSize.width = tmpInt;
			tmpInt = 1;
			while (tmpInt < dxtImgSize.height)
				tmpInt = tmpInt<<1;
			dxtTexSize.height = tmpInt;
			
			OSType codecSubType = [dxtFrame codecSubType];
			if (!mHapShader) {
				if (codecSubType == kHapYCoCgCodecSubType) {
					mHapShader = gl::GlslProg::create(gl::GlslProg::Format().vertex( passTextureVertexShader() ).fragment( hapCoCgYToRGBAShader() ));
					mHapShader->uniform( "cocgsy_src", 0 );
				}
				else if (codecSubType == kHapYCoCgACodecSubType) {
					// TODO: YCoCgAlpha
					mHapShader = gl::GlslProg::create(gl::GlslProg::Format().vertex( passTextureVertexShader() ).fragment( hapCoCgYToRGBAShader() ));
					mHapShader->uniform( "cocgsy_src", 0 );
				}
				else {
					mHapShader = gl::GlslProg::create(gl::GlslProg::Format().vertex( passTextureVertexShader() ).fragment( passTextureFragmentShader() ));
				}
			}
			
			//	pass the decoded frame to the hap texture
			[mHapTexture setDecodedFrame:dxtFrame];
			newFrame(GL_TEXTURE_2D, [mHapTexture textureNames][0], imgSize.width, imgSize.height, dxtTexSize.width, dxtTexSize.height);
			[dxtFrame release];
			
			mSignalNewFrame.emit();
			
			return;
		}
#endif
		if( [mPlayerVideoOutput hasNewPixelBufferForItemTime:vTime] ) {
			releaseFrame();
			
			CVImageBufferRef buffer = nil;
			buffer = [mPlayerVideoOutput copyPixelBufferForItemTime:vTime itemTimeForDisplay:nil];
			if( buffer ) {
				newFrame( buffer );
				mSignalNewFrame.emit();
			}
		}
	}
}

uint32_t MovieBase::countFrames() const
{
	if( ! mAsset )
		return 0;
	
	CMTime dur = [mAsset duration];
	CMTime one_frame = ::CMTimeMakeWithSeconds( 1.0 / mFrameRate, dur.timescale );
	double dur_seconds = ::CMTimeGetSeconds( dur );
	double one_frame_seconds = ::CMTimeGetSeconds( one_frame );
	return static_cast<uint32_t>(dur_seconds / one_frame_seconds);
}

static NSString * FourCCString(FourCharCode code) {
	NSString *result = [NSString stringWithFormat:@"%c%c%c%c",
						(code >> 24) & 0xff,
						(code >> 16) & 0xff,
						(code >> 8) & 0xff,
						code & 0xff];
	NSCharacterSet *characterSet = [NSCharacterSet whitespaceCharacterSet];
	return [result stringByTrimmingCharactersInSet:characterSet];
}
	
NSString* MovieBase::getVideoFormat(AVAsset* asset) {
	NSArray<AVAssetTrack *>* videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
	
	NSMutableString *format = [[NSMutableString alloc] init];
	for (int i = 0; i < videoTracks.count; i++) {
		AVAssetTrack *assetTrack = videoTracks[i];

		NSArray	*descs = [assetTrack formatDescriptions];
		if (descs != nil) {
			for (int j = 0; j < assetTrack.formatDescriptions.count; j++) {
				CMFormatDescriptionRef desc = (__bridge CMFormatDescriptionRef) assetTrack.formatDescriptions[i];
				
				NSString *subType = FourCCString(CMFormatDescriptionGetMediaSubType(desc)); // Get String representation media subtype (avc1, aac, tx3g, etc.)
				[format appendString: subType];
				
				// Comma separate if more than one format description
				if (j < assetTrack.formatDescriptions.count - 1) {
					[format appendString:@","];
				}
			}
		}
		else {
			[format appendString: @"NoDescription"];
		}
	}
	return format;
}
	
std::string MovieBase::getMediaFormatString() {
	if (mAsset == NULL) return "NotLoaded";
	
	NSArray<AVAssetTrack *>* assetTracks = [mAsset tracks];
	
	NSMutableString *format = [[NSMutableString alloc] init];
	for (int i = 0; i < assetTracks.count; i++) {
		AVAssetTrack *assetTrack = assetTracks[i];
		
//		for (id formatDescription in assetTrack.formatDescriptions) NSLog(@"formatDescription:  %@", formatDescription);
		
		NSArray	*descs = [assetTrack formatDescriptions];
		if (descs != nil) {
			
			for (int j = 0; j < descs.count; j++) {
				CMFormatDescriptionRef desc = (__bridge CMFormatDescriptionRef) assetTrack.formatDescriptions[j];
				
			    NSString *type = FourCCString(CMFormatDescriptionGetMediaType(desc)); // Get String representation of media type (vide, soun, sbtl, etc.)
				NSString *subType = FourCCString(CMFormatDescriptionGetMediaSubType(desc)); // Get String representation media subtype (avc1, aac, tx3g, etc.)

				if([type compare:@"vide"] == NSOrderedSame) {
					CFDictionaryRef inputFormatDescriptionExtension = CMFormatDescriptionGetExtensions(desc);
					CFTypeRef formatName = CFDictionaryGetValue(inputFormatDescriptionExtension, kCMFormatDescriptionExtension_FormatName);

					[format appendFormat:@"%@ (%@)", formatName, subType];
				}
				else {
					[format appendFormat:@"%@", subType];
				}
				// Comma separate if more than one format description
				if (j < assetTrack.formatDescriptions.count - 1) {
					[format appendString:@", "];
				}
			}
		}
		else {
			[format appendString: @"NoDescription"];
		}
		
		// Separate if more than one asset track
		if (i < assetTracks.count - 1) {
			[format appendString:@" / "];
		}
	}
	return std::string([format UTF8String]);;
}
	
void MovieBase::processAssetTracks( AVAsset* asset )
{
	// process video tracks
	NSArray<AVAssetTrack *>* videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
	
	mHasVideo = [videoTracks count] > 0;
	if( mHasVideo ) {
		AVAssetTrack* videoTrack = [videoTracks firstObject];
		if( videoTrack ) {
			// Grab track dimensions from format description
			CGSize size = [videoTrack naturalSize];
			CGAffineTransform trans = [videoTrack preferredTransform];
			size = CGSizeApplyAffineTransform(size, trans);
			mHeight = static_cast<int32_t>(size.height);
			mWidth = static_cast<int32_t>(size.width);
			mFrameRate = [videoTrack nominalFrameRate];
		}
		else
			throw AvfFileInvalidExc();
	}
	
	if (!videoOnly) {
	// process audio tracks
		NSArray* audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
		mHasAudio = [audioTracks count] > 0;
#if defined( CINDER_COCOA_TOUCH )
		if( mHasAudio ) {
			setAudioSessionModes();
		}
#elif defined( CINDER_COCOA )
		// No need for changes on OSX
	
#endif
	}
}

void MovieBase::createPlayerItemOutput( const AVPlayerItem* playerItem )
{
	AVPlayerItemVideoOutput *oldPlayerVideoOutput = mPlayerVideoOutput;
	mPlayerVideoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:avPlayerItemOutputDictionary()];
	[oldPlayerVideoOutput release];
	dispatch_queue_t outputQueue = dispatch_queue_create("movieVideoOutputQueue", DISPATCH_QUEUE_SERIAL);
	[mPlayerVideoOutput setDelegate:mPlayerDelegate queue:outputQueue];
	dispatch_release(outputQueue);
	mPlayerVideoOutput.suppressesPlayerRendering = YES;
	[playerItem addOutput:mPlayerVideoOutput];

#ifdef USE_HAP
	if (mPlayerHapOutput != nil)	{
		if (playerItem != nil)
			[playerItem removeOutput:mPlayerHapOutput];
	}
	else {
		mPlayerHapOutput = [[AVPlayerItemHapDXTOutput alloc] init];
		mPlayerHapOutput.suppressesPlayerRendering = YES;
	}
	[playerItem addOutput:mPlayerHapOutput];
#endif
}

void MovieBase::addObservers()
{
	if( mPlayerDelegate && mPlayerItem ) {
		// Determine if this is all we need out of the NotificationCenter
		NSNotificationCenter* notification_center = [NSNotificationCenter defaultCenter];
		[notification_center addObserver:mPlayerDelegate
								selector:@selector(playerItemDidNotReachEndCallback)
									name:AVPlayerItemFailedToPlayToEndTimeNotification
								  object:mPlayerItem];
		
		[notification_center addObserver:mPlayerDelegate
								selector:@selector(playerItemDidReachEndCallback)
									name:AVPlayerItemDidPlayToEndTimeNotification
								  object:mPlayerItem];
		
		[notification_center addObserver:mPlayerDelegate
								selector:@selector(playerItemTimeJumpedCallback)
									name:AVPlayerItemTimeJumpedNotification
								  object:mPlayerItem];
		
		[mPlayerItem addObserver:mPlayerDelegate
					  forKeyPath:@"status"
						 options:(NSKeyValueObservingOptions)0
						 context:AVPlayerItemStatusContext];
	}
}

void MovieBase::removeObservers()
{
	if( mPlayerDelegate && mPlayerItem ) {
		NSNotificationCenter* notify_center = [NSNotificationCenter defaultCenter];
		[notify_center removeObserver:mPlayerDelegate
								 name:AVPlayerItemFailedToPlayToEndTimeNotification
							   object:mPlayerItem];
		
		[notify_center removeObserver:mPlayerDelegate
								 name:AVPlayerItemDidPlayToEndTimeNotification
							   object:mPlayerItem];
		
		[notify_center removeObserver:mPlayerDelegate
								 name:AVPlayerItemTimeJumpedNotification
							   object:mPlayerItem];
		
		[mPlayerItem removeObserver:mPlayerDelegate
						 forKeyPath:@"status"];
	}
}
	
	bool printSignals = false;
	
void MovieBase::playerReady()
{
	if (printSignals) app::console() << "playerReady" << std::endl;
	mPlayable = true;
	
	mSignalReady.emit();
	
	if( mPlaying )
		play();
}
	
void MovieBase::playerItemEnded()
{
	if (printSignals) app::console() << "playerItemEnded" << std::endl;
	
	if( mPalindrome ) {
		float rate = -[mPlayer rate];
		mPlayingForward = (rate >= 0);
		this->setRate( rate );
	}
	else if( mLoop ) {
		this->seekToStart();
		this->play();
	}
	
	mSignalEnded.emit();
}
	
void MovieBase::playerItemCancelled()
{
	if (printSignals) app::console() << "playerItemCancelled" << std::endl;
	
	mSignalCancelled.emit();
}
	
void MovieBase::playerItemJumped()
{
	if (printSignals) app::console() << "playerItemJumped" << std::endl;
	mSignalJumped.emit();
}

void MovieBase::outputWasFlushed( AVPlayerItemOutput* output )
{
	if (printSignals) app::console() << "outputWasFlushed" << std::endl;
	mSignalOutputWasFlushed.emit();
}

/////////////////////////////////////////////////////////////////////////////////
// MovieSurface
MovieSurface::MovieSurface( const Url& url )
	: MovieBase()
{
	MovieBase::initFromUrl( url );
}

MovieSurface::MovieSurface( const fs::path& path )
	: MovieBase()
{
	MovieBase::initFromPath( path );
}

MovieSurface::MovieSurface( const MovieLoader& loader )
	: MovieBase()
{
	MovieBase::initFromLoader( loader );
}

MovieSurface::~MovieSurface()
{
#ifdef USE_HAP
	if(mHapTexture)
		[mHapTexture release];
#endif
	deallocateVisualContext();
}

NSDictionary* MovieSurface::avPlayerItemOutputDictionary() const
{
	return [NSDictionary dictionaryWithObjectsAndKeys:
				[NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
				nil];
}

Surface8uRef MovieSurface::getSurface()
{
	updateFrame();
	
	lock();
	Surface8uRef result = mSurface;
	unlock();
	
	return result;
}

void MovieSurface::newFrame( CVImageBufferRef cvImage )
{
	CVPixelBufferRef imgRef = reinterpret_cast<CVPixelBufferRef>( cvImage );
	if( imgRef )
		mSurface = convertCvPixelBufferToSurface( imgRef );
	else
		mSurface.reset();
}

void MovieSurface::releaseFrame()
{
	mSurface.reset();
}

/////////////////////////////////////////////////////////////////////////////////
// MovieLoader
MovieLoader::MovieLoader( const Url &url )
	:mUrl(url), mBufferFull(false), mBufferEmpty(false), mLoaded(false),
		mPlayable(false), mPlayThroughOK(false), mProtected(false), mOwnsMovie(true)
{
	NSURL* asset_url = [NSURL URLWithString:[NSString stringWithCString:mUrl.c_str() encoding:[NSString defaultCStringEncoding]]];
	if( ! asset_url )
		throw AvfUrlInvalidExc();
	
	AVPlayerItem* playerItem = [[AVPlayerItem alloc] initWithURL:asset_url];
	mPlayer = [[AVPlayer alloc] init];
	[mPlayer replaceCurrentItemWithPlayerItem:playerItem];	// starts the downloading process
	[playerItem release];
}

MovieLoader::~MovieLoader()
{
	if( mOwnsMovie && mPlayer ) {
		[mPlayer release];
	}
}
	
bool MovieLoader::checkLoaded() const
{
	if( ! mLoaded )
		updateLoadState();
	
	return mLoaded;
}

bool MovieLoader::checkPlayable() const
{
	if( ! mPlayable )
		updateLoadState();
	
	return mPlayable;
}

bool MovieLoader::checkPlaythroughOk() const
{
	if( ! mPlayThroughOK )
		updateLoadState();
	
	return mPlayThroughOK;
}

bool MovieLoader::checkProtection() const
{
	updateLoadState();
	
	return mProtected;
}

void MovieLoader::waitForLoaded() const
{
	// Accessing the AVAssets properties (such as duration, tracks, etc) will block the thread until they're available...
	NSArray* video_tracks = [[[mPlayer currentItem] asset] tracksWithMediaType:AVMediaTypeVideo];
	mLoaded = [video_tracks count] > 0;
}

void MovieLoader::waitForPlayable() const
{
	while( ! mPlayable ) {
		cinder::sleep( 250 );
		updateLoadState();
	}
}

void MovieLoader::waitForPlayThroughOk() const
{
	while( ! mPlayThroughOK ) {
		cinder::sleep( 250 );
		updateLoadState();
	}
}

void MovieLoader::updateLoadState() const
{
	AVPlayerItem* playerItem = [mPlayer currentItem];
	mLoaded = mPlayable = [playerItem status] == AVPlayerItemStatusReadyToPlay;
	mPlayThroughOK = [playerItem isPlaybackLikelyToKeepUp];
	mProtected = [[playerItem asset] hasProtectedContent];
	
	//NSArray* loaded = [playerItem seekableTimeRanges];  // this value appears to be garbage
/*	NSArray* loaded = [playerItem loadedTimeRanges];      // this value appears to be garbage
	for( NSValue* value in loaded ) {
		CMTimeRange range = [value CMTimeRangeValue];
		float start = ::CMTimeGetSeconds( range.start );
		float dur = ::CMTimeGetSeconds( range.duration );
		//mLoaded = (CMTimeCompare([playerItem duration], range.duration) >= 0);
	}
	
	AVPlayerItemAccessLog* log = [playerItem accessLog];
	if( log ) {
		NSArray* load_events = [log events];
		for (AVPlayerItemAccessLogEvent* log_event in load_events) {
			int segments = log_event.numberOfSegmentsDownloaded;
			int stalls = log_event.numberOfStalls;							// only accurate if playing!
			double segment_interval = log_event.segmentsDownloadedDuration;	// only accurate if playing!
			double watched_interval = log_event.durationWatched;			// only accurate if playing!
			NSString* str = log_event.serverAddress;
			std::string address = (str? std::string([str UTF8String]): "");
			long long bytes_transfered = log_event.numberOfBytesTransferred;
			double bitrate = log_event.observedBitrate;
			int dropped_frames = log_event.numberOfDroppedVideoFrames;		// only accurate if playing!
		}
	}*/
}

} } // namespace cinder::qtime

#ifdef USE_HAP
/*
 HapPixelBufferTexture.m
 Hap QuickTime Playback
 
 Copyright (c) 2012-2013, Tom Butterworth and Vidvox LLC. All rights reserved.
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <OpenGL/CGLMacro.h>

#define FourCCLog(n,f) NSLog(@"%@, %c%c%c%c",n,(int)((f>>24)&0xFF),(int)((f>>16)&0xFF),(int)((f>>8)&0xFF),(int)((f>>0)&0xFF))


@interface HapPixelBufferTexture (Shader)
- (GLhandleARB)loadShaderOfType:(GLenum)type named:(NSString *)name;
@end




@implementation HapPixelBufferTexture
- (id)initWithContext:(CGLContextObj)context
{
	self = [super init];
	if (self)
	{
		textureCount = 0;
		for (int i=0; i<2; ++i)	{
			textures[i] = 0;
			backingHeights[i] = 0;
			backingWidths[i] = 0;
			internalFormats[i] = 0;
		}
		decodedFrame = nil;
		width = 0;
		height = 0;
		valid = NO;
		shader = 0;
		alphaShader = 0;
		cgl_ctx = CGLRetainContext(context);
	}
	return self;
}

- (void)dealloc
{
	for (int texIndex=0; texIndex<textureCount; ++texIndex)	{
		if (textures[texIndex] != 0)
			glDeleteTextures(1,&(textures[texIndex]));
	}
	if (shader != NULL) glDeleteObjectARB(shader);
	if (alphaShader != NULL) glDeleteObjectARB(alphaShader);
	if (decodedFrame!=nil)	{
		[decodedFrame release];
		decodedFrame = nil;
	}
	CGLReleaseContext(cgl_ctx);
	[super dealloc];
}
- (void) setDecodedFrame:(HapDecoderFrame *)newFrame	{
	[newFrame retain];
	
	[decodedFrame release];
	decodedFrame = newFrame;
	
	valid = NO;
	
	if (decodedFrame == NULL)
	{
		NSLog(@"\t\terr: decodedFrame nil, bailing. %s",__func__);
		return;
	}
	
	NSSize			tmpSize = [decodedFrame imgSize];
	width = tmpSize.width;
	height = tmpSize.height;
	
	tmpSize = [decodedFrame dxtImgSize];
	GLuint			roundedWidth = tmpSize.width;
	GLuint			roundedHeight = tmpSize.height;
	if (roundedWidth % 4 != 0 || roundedHeight % 4 != 0)	{
		NSLog(@"\t\terr: width isn't a multiple of 4, bailing. %s",__func__);
		return;
	}
	
	textureCount = [decodedFrame dxtPlaneCount];
	OSType			*dxtPixelFormats = [decodedFrame dxtPixelFormats];
	GLenum			newInternalFormat;
	size_t			*dxtDataSizes = [decodedFrame dxtDataSizes];
	void			**dxtBaseAddresses = [decodedFrame dxtDatas];
	for (int texIndex=0; texIndex<textureCount; ++texIndex)	{
		unsigned int	bitsPerPixel = 0;
		switch (dxtPixelFormats[texIndex]) {
			case kHapCVPixelFormat_RGB_DXT1:
				newInternalFormat = HapTextureFormat_RGB_DXT1;
				bitsPerPixel = 4;
				break;
			case kHapCVPixelFormat_RGBA_DXT5:
			case kHapCVPixelFormat_YCoCg_DXT5:
				newInternalFormat = HapTextureFormat_RGBA_DXT5;
				bitsPerPixel = 8;
				break;
			case kHapCVPixelFormat_CoCgXY:
				if (texIndex==0)	{
					newInternalFormat = HapTextureFormat_RGBA_DXT5;
					bitsPerPixel = 8;
				}
				else	{
					newInternalFormat = HapTextureFormat_A_RGTC1;
					bitsPerPixel = 4;
				}
				
				//newInternalFormat = HapTextureFormat_RGBA_DXT5;
				//bitsPerPixel = 8;
				break;
			case kHapCVPixelFormat_YCoCg_DXT5_A_RGTC1:
				if (texIndex==0)	{
					newInternalFormat = HapTextureFormat_RGBA_DXT5;
					bitsPerPixel = 8;
				}
				else	{
					newInternalFormat = HapTextureFormat_A_RGTC1;
					bitsPerPixel = 4;
				}
				break;
			case kHapCVPixelFormat_A_RGTC1:
				newInternalFormat = HapTextureFormat_A_RGTC1;
				bitsPerPixel = 4;
				break;
			default:
				// we don't support non-DXT pixel buffers
				NSLog(@"\t\terr: unrecognized pixel format (%X) at index %d in %s",dxtPixelFormats[texIndex],texIndex,__func__);
				FourCCLog(@"\t\tpixel format fourcc is",dxtPixelFormats[texIndex]);
				valid = NO;
				return;
				break;
		}
		size_t			bytesPerRow = (roundedWidth * bitsPerPixel) / 8;
		GLsizei			newDataLength = (int)(bytesPerRow * roundedHeight);
		size_t			actualBufferSize = dxtDataSizes[texIndex];
		
		//	make sure the buffer's at least as big as necessary
		if (newDataLength > actualBufferSize)	{
			NSLog(@"\t\terr: new data length incorrect, %d vs %ld in %s",newDataLength,actualBufferSize,__func__);
			valid = NO;
			return;
		}
		
		//	if we got this far we're good to go
		
		valid = YES;
		
		glActiveTexture(GL_TEXTURE0);
		
		GLvoid		*baseAddress = dxtBaseAddresses[texIndex];
		
		// Create a new texture if our current one isn't adequate
		
		if (textures[texIndex] == 0	||
			roundedWidth > backingWidths[texIndex] ||
			roundedHeight > backingHeights[texIndex] ||
			newInternalFormat != internalFormats[texIndex])
		{
			if (textures[texIndex] != 0)
			{
				glDeleteTextures(1, &(textures[texIndex]));
			}
			
			glGenTextures(1, &(textures[texIndex]));
			
			glBindTexture(GL_TEXTURE_2D, textures[texIndex]);
			
			// On NVIDIA hardware there is a massive slowdown if DXT textures aren't POT-dimensioned, so we use POT-dimensioned backing
			//	NOTE: NEEDS TESTING. this used to be the case- but this API is only available on 10.10+, so this may have been fixed.
			backingWidths[texIndex] = 1;
			while (backingWidths[texIndex] < roundedWidth) backingWidths[texIndex] <<= 1;
			backingHeights[texIndex] = 1;
			while (backingHeights[texIndex] < roundedHeight) backingHeights[texIndex] <<= 1;
			
			//	...if we aren't doing POT dimensions, then we need to do this!
			//backingWidths[texIndex] = roundedWidth;
			//backingHeights[texIndex] = roundedHeight;
			
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_STORAGE_HINT_APPLE , GL_STORAGE_SHARED_APPLE);
			
			// We allocate the texture with no pixel data, then use CompressedTexSubImage to update the content region
			
			glTexImage2D(GL_TEXTURE_2D, 0, newInternalFormat, backingWidths[texIndex], backingHeights[texIndex], 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, NULL);
			
			internalFormats[texIndex] = newInternalFormat;
		}
		else
		{
			glBindTexture(GL_TEXTURE_2D, textures[texIndex]);
		}
		
		glTextureRangeAPPLE(GL_TEXTURE_2D, newDataLength, baseAddress);
		//glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_TRUE);
		
		glCompressedTexSubImage2D(GL_TEXTURE_2D,
								  0,
								  0,
								  0,
								  roundedWidth,
								  roundedHeight,
								  newInternalFormat,
								  newDataLength,
								  baseAddress);
		
		cinder::gl::checkError();
	}
}
- (HapDecoderFrame *) decodedFrame	{
	return decodedFrame;
}

- (int) textureCount
{
	return textureCount;
}
- (GLuint *)textureNames
{
	if (!valid) return 0;
	return textures;
}

- (GLuint)width
{
	if (valid) return width;
	else return 0;
}

- (GLuint)height
{
	if (valid) return height;
	else return 0;
}

- (GLuint*)textureWidths
{
	if (!valid) return 0;
	return backingWidths;
}

- (GLuint*)textureHeights
{
	if (!valid) return 0;
	return backingHeights;
}
@end

#endif // USE_HAP

#endif // defined( CINDER_COCOA_TOUCH ) || ( defined( CINDER_MAC ) && ( MAC_OS_X_VERSION_MIN_REQUIRED >= 1080 ) )
