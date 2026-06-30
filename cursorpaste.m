#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

static const CGFloat kMaxSide = 220.0;
static const CGFloat kMinSide = 40.0;
static const CGFloat kHoverOffsetX = 14.0;

static void LogHelper(NSString *message) {
    NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
    NSString *line = [message stringByAppendingString:@"\n"];
    [stderrHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
}

@interface CursorPasteController : NSObject
@property(nonatomic, strong) NSImage *image;
@property(nonatomic, strong) NSURL *fileURL;
@property(nonatomic, assign) BOOL trusted;
@property(nonatomic, assign) NSSize thumbSize;

@property(nonatomic, strong) NSPanel *hoverPanel;
@property(nonatomic, strong) NSImageView *hoverImageView;
@property(nonatomic, strong) NSMutableArray *monitors;
@property(nonatomic, strong) NSTimer *followTimer;

@property(nonatomic, assign) BOOL finished;
@property(nonatomic, assign) BOOL pasteInFlight;
- (void)sendLeftClickAt:(NSPoint)point;
- (void)handleGlobalMouseUp:(NSEvent *)event;
@end

@implementation CursorPasteController

- (instancetype)initWithImage:(NSImage *)image fileURL:(NSURL *)fileURL trusted:(BOOL)trusted {
    self = [super init];
    if (!self) return nil;

    _image = image;
    _fileURL = fileURL;
    _trusted = trusted;
    _monitors = [NSMutableArray array];

    NSSize imageSize = image.size;
    CGFloat longestSide = MAX(imageSize.width, imageSize.height);
    CGFloat scale = longestSide > 0 ? MIN(1.0, kMaxSide / longestSide) : 1.0;
    _thumbSize = NSMakeSize(MAX(kMinSide, imageSize.width * scale),
                            MAX(kMinSide, imageSize.height * scale));

    _hoverPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, _thumbSize.width, _thumbSize.height)
                                             styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    _hoverPanel.floatingPanel = YES;
    _hoverPanel.level = NSScreenSaverWindowLevel;
    _hoverPanel.backgroundColor = [NSColor clearColor];
    _hoverPanel.opaque = NO;
    _hoverPanel.hasShadow = YES;
    _hoverPanel.ignoresMouseEvents = YES;
    _hoverPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary |
                                     NSWindowCollectionBehaviorStationary;
    _hoverPanel.alphaValue = 0.92;

    _hoverImageView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, _thumbSize.width, _thumbSize.height)];
    _hoverImageView.image = image;
    _hoverImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _hoverImageView.wantsLayer = YES;
    _hoverImageView.layer.cornerRadius = 8.0;
    _hoverImageView.layer.masksToBounds = YES;
    _hoverImageView.layer.borderWidth = 2.0;
    _hoverImageView.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.85] CGColor];
    _hoverPanel.contentView = _hoverImageView;

    return self;
}

- (void)start {
    [self showHover];
    [self repositionHover];

    self.followTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 120.0)
                                                        target:self
                                                      selector:@selector(repositionHover)
                                                      userInfo:nil
                                                       repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.followTimer forMode:NSRunLoopCommonModes];

    __weak typeof(self) weakSelf = self;
    id monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                        handler:^(NSEvent *event) {
        if (event.keyCode == 53) {
            [weakSelf finish:1];
        }
    }];
    if (monitor) {
        [self.monitors addObject:monitor];
    }
    id mouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                                             handler:^(NSEvent *event) {
        [weakSelf handleGlobalMouseUp:event];
    }];
    if (mouseMonitor) {
        [self.monitors addObject:mouseMonitor];
    }
}

- (void)handleGlobalMouseUp:(NSEvent *)event {
    if (self.pasteInFlight || self.finished) {
        return;
    }
    self.pasteInFlight = YES;
    [self performPasteFallbackAt:[NSEvent mouseLocation]];
}

- (void)performPasteFallbackAt:(NSPoint)screenPoint {
    [self copyToPasteboard];
    LogHelper(@"cursorpaste: copied screenshot to pasteboard");

    if (!self.trusted) {
        LogHelper(@"cursorpaste: click-to-paste blocked because Accessibility trust is missing");
        [self finish:1];
        return;
    }

    [self hideHover];

    LogHelper([NSString stringWithFormat:@"cursorpaste: sending focus click at %.1f, %.1f", screenPoint.x, screenPoint.y]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sendLeftClickAt:screenPoint];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSRunningApplication *frontmost = [[NSWorkspace sharedWorkspace] frontmostApplication];
            NSString *bundleID = frontmost.bundleIdentifier ?: @"";
            if ([self shouldTypeFilePathForBundleID:bundleID]) {
                LogHelper([NSString stringWithFormat:@"cursorpaste: frontmost app %@ looks like a terminal; typing file path", bundleID]);
                [self sendFilePathText];
            } else {
                LogHelper([NSString stringWithFormat:@"cursorpaste: frontmost app %@ supports normal paste; sending Cmd+V", bundleID]);
                [self sendPaste];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self finish:0];
            });
        });
    });
}

- (void)copyToPasteboard {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];

    NSBitmapImageRep *rep = nil;
    NSData *tiff = [self.image TIFFRepresentation];
    NSData *png = nil;
    if (tiff) {
        rep = [NSBitmapImageRep imageRepWithData:tiff];
        png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    }

    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    if (png) {
        [item setData:png forType:NSPasteboardTypePNG];
    }
    if (tiff) {
        [item setData:tiff forType:NSPasteboardTypeTIFF];
    }

    NSMutableArray *objects = [NSMutableArray arrayWithObject:self.fileURL];
    if (png || tiff) {
        [objects insertObject:item atIndex:0];
    }
    [pb writeObjects:objects];
}

- (void)sendPaste {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    if (!src) {
        LogHelper(@"cursorpaste: failed to create keyboard event source");
        return;
    }

    CGKeyCode vKey = 0x09;
    CGEventRef down = CGEventCreateKeyboardEvent(src, vKey, true);
    CGEventRef up = CGEventCreateKeyboardEvent(src, vKey, false);
    if (down) {
        CGEventSetFlags(down, kCGEventFlagMaskCommand);
        CGEventPost(kCGHIDEventTap, down);
        CFRelease(down);
    }
    if (up) {
        CGEventSetFlags(up, kCGEventFlagMaskCommand);
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(up);
    }
    CFRelease(src);
}

- (BOOL)shouldTypeFilePathForBundleID:(NSString *)bundleID {
    static NSSet<NSString *> *terminalBundleIDs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        terminalBundleIDs = [NSSet setWithArray:@[
            @"com.apple.Terminal",
            @"com.googlecode.iterm2",
            @"dev.warp.Warp-Stable",
            @"dev.warp.Warp",
            @"com.mitchellh.ghostty",
            @"org.alacritty",
            @"net.kovidgoyal.kitty",
            @"co.zeit.hyper",
            @"org.wezfurlong.wezterm"
        ]];
    });
    return [terminalBundleIDs containsObject:bundleID];
}

- (NSString *)shellEscapedPath {
    NSString *path = self.fileURL.path ?: @"";
    NSString *escaped = [path stringByReplacingOccurrencesOfString:@"'" withString:@"'\"'\"'"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

- (void)sendFilePathText {
    NSString *text = [self shellEscapedPath];
    if (text.length == 0) {
        LogHelper(@"cursorpaste: empty file path; cannot type path");
        return;
    }

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *priorString = [pb stringForType:NSPasteboardTypeString];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
    LogHelper([NSString stringWithFormat:@"cursorpaste: typing file path %@", text]);
    [self sendPaste];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [pb clearContents];
        if (priorString.length > 0) {
            [pb setString:priorString forType:NSPasteboardTypeString];
        }
    });
}

- (void)sendLeftClickAt:(NSPoint)point {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    if (!src) {
        LogHelper(@"cursorpaste: failed to create mouse event source");
        return;
    }

    CGPoint cgPoint = CGPointMake(point.x, point.y);
    CGEventRef down = CGEventCreateMouseEvent(src, kCGEventLeftMouseDown, cgPoint, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(src, kCGEventLeftMouseUp, cgPoint, kCGMouseButtonLeft);
    if (down) {
        CGEventPost(kCGHIDEventTap, down);
        CFRelease(down);
    }
    if (up) {
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(up);
    }
    CFRelease(src);
}

- (void)repositionHover {
    if (self.finished) {
        return;
    }
    NSPoint mouse = [NSEvent mouseLocation];
    [self.hoverPanel setFrameOrigin:NSMakePoint(mouse.x + kHoverOffsetX,
                                                mouse.y - self.thumbSize.height - kHoverOffsetX)];
}

- (void)showHover {
    [self.hoverPanel orderFrontRegardless];
}

- (void)hideHover {
    [self.hoverPanel orderOut:nil];
}

- (void)finish:(int)code {
    if (self.finished) return;
    self.finished = YES;

    [self.followTimer invalidate];
    self.followTimer = nil;

    for (id monitor in self.monitors) {
        [NSEvent removeMonitor:monitor];
    }
    [self.monitors removeAllObjects];

    [self hideHover];
    exit(code);
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: cursorpaste <image-path>\n");
            return 2;
        }

        NSString *imagePath = [NSString stringWithUTF8String:argv[1]];
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:imagePath];
        if (!image) {
            fprintf(stderr, "cursorpaste: cannot load image %s\n", argv[1]);
            return 2;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
        BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
        if (!trusted) {
            fprintf(stderr, "cursorpaste: Accessibility permission not granted; drag/drop will still work, but click-to-paste needs it.\n");
        } else {
            fprintf(stderr, "cursorpaste: Accessibility permission granted.\n");
        }

        CursorPasteController *controller = [[CursorPasteController alloc] initWithImage:image
                                                                                 fileURL:[NSURL fileURLWithPath:imagePath]
                                                                                 trusted:trusted];
        [controller start];
        [NSApp run];
    }
    return 0;
}
