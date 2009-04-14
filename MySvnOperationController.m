#import "MySvnOperationController.h"
#import "MySvnRepositoryBrowserView.h"
#import "NSString+MyAdditions.h"
#include "DbgUtils.h"


@implementation MySvnOperationController

//----------------------------------------------------------------------------------------
// Private:

- (void) setupUrl:   (NSURL*)        url
		 options:    (NSInvocation*) options
		 sourceItem: (NSDictionary*) sourceItem
{
    if (svnOptionsInvocation != options)
	{
		[svnOptionsInvocation release];
		svnOptionsInvocation = [options retain];
	}

	if ([targetBrowser respondsToSelector: @selector(setSvnOptionsInvocation:)])
		[targetBrowser setSvnOptionsInvocation: options];

	[targetBrowser setUrl: url];
	[objectController setValue: url forKeyPath: @"content.itemUrl"];
	if (sourceItem != nil)
	{
		[objectController setValue: sourceItem forKeyPath: @"content.sourceItem"];
		[targetName setStringValue:[[sourceItem objectForKey: @"path"] lastPathComponent]];
	}

	if (svnOperation == kSvnDelete)
	{
		[targetBrowser setupForSubBrowser: NO allowsLeaves: YES allowsMultipleSelection: YES];
	}
	else
	{
		Assert(svnOperation != kSvnDiff);
		if (svnOperation == kSvnMove)
			[objectController setValue:@"HEAD" forKeyPath:@"content.sourceItem.revision"];

		[targetBrowser setupForSubBrowser: YES allowsLeaves: NO allowsMultipleSelection: NO];
	}
}


//----------------------------------------------------------------------------------------
// Private:

- (id) initSheet:  (SvnOperation)  operation
	   repository: (MyRepository*) repository
	   url:        (NSURL*)        url
	   sourceItem: (NSDictionary*) sourceItem
{
	Assert(operation >= kSvnCopy && operation <= kSvnDiff);

	if (self = [super init])
	{
	//	NSLog(@"MySvnOperationController::initSheet: 0x%X operation=%d", self, operation);
		static NSString* const nibNames[] = {
			// kSvnCopy, kSvnMove, kSvnDelete, kSvnMkdir, kSvnDiff
			@"svnCopy", @"svnCopy", @"svnDelete", @"svnMkdir", @"svnFileMergeFromRepository"
		};
		NSString* nibName = nibNames[operation];

		svnOperation = operation;
		if ([NSBundle loadNibNamed: nibName owner: self])
		{
			[self setupUrl: url options: [repository svnOptionsInvocation]
				  sourceItem: sourceItem];

			[NSApp beginSheet:     svnSheet
				   modalForWindow: [repository windowForSheet]
				   modalDelegate:  repository
				   didEndSelector: @selector(sheetDidEnd:returnCode:contextInfo:)
				   contextInfo:    self];
		}
		else if (qDebug)
			NSLog(@"initSheet: loadNibNamed '%@' FAILED", nibName);
	}

	return self;
}


//----------------------------------------------------------------------------------------

+ (void) runSheet:   (SvnOperation)  operation
		 repository: (MyRepository*) repository
		 url:        (NSURL*)        url
		 sourceItem: (NSDictionary*) sourceItem
{
	[[self alloc] initSheet: operation repository: repository url: url sourceItem: sourceItem];
}


//----------------------------------------------------------------------------------------

#if qDebug && 0
- (void) dealloc
{
	NSLog(@"MySvnOperationController::dealloc: 0x%X operation=%d", self, svnOperation);
	[super dealloc];
}
#endif


- (void) finished
{
	[targetBrowser setRevision:nil];
	[targetBrowser reset];
	[targetBrowser unload]; // targetBrowser was loaded from a nib (see "unload" comments).

	// the owner has to release its top level nib objects 
	[svnSheet release];
	[objectController release];

	[self release];
}


//----------------------------------------------------------------------------------------
// Transform the text into something, vaguely, legal for a file name

- (NSString*) getTargetName
{
	NSMutableString* text = [NSMutableString stringWithString: [targetName stringValue]];
	[text replaceOccurrencesOfString: @"/" withString: @":"
		  options: NSLiteralSearch range: NSMakeRange(0, [text length])];

	NSRange range;
	int len = [text length];
	if (len >= 128)
	{
		range.location = 128;
		range.length   = len - 128;
		[text deleteCharactersInRange: range];
	}
	NSCharacterSet* chSet = [NSCharacterSet controlCharacterSet];
	while ((range = [text rangeOfCharacterFromSet: chSet]).location != NSNotFound)
		[text replaceCharactersInRange: range withString: @"-"];

	chSet = [NSCharacterSet characterSetWithCharactersInString: @"[];?"];	// reserved: ";?@&=+$,"
	while ((range = [text rangeOfCharacterFromSet: chSet]).location != NSNotFound)
		[text replaceCharactersInRange: range withString: @"-"];

	return text;
}


//----------------------------------------------------------------------------------------

- (NSString*) getTargetPath
{
	return [[[[targetBrowser selectedItems] objectAtIndex: 0] objectForKey: @"path"]
				stringByAppendingPathComponent: [self getTargetName]];
}


- (NSURL*) getTargetUrl
{
	NSURL* url = [[[targetBrowser selectedItems] objectAtIndex: 0] objectForKey: @"url"];
	return [NSURL URLWithString: [[self getTargetName] escapeURL] relativeToURL: url];
}


- (NSString*) getCommitMessage
{
	return MessageString([commitMessage string]);
}


- (NSArray*) getTargets
{
	return [arrayController arrangedObjects];
}


- (IBAction) addDirectory: (id) sender
{
	if ([[self getTargetName] length] == 0)
	{
		[svnSheet makeFirstResponder: targetName];
		NSBeep();
	}
	else
	{
		id dir = [NSDictionary dictionaryWithObjectsAndKeys: [self getTargetPath], @"path",
															 [self getTargetUrl],  @"url",
															 nil];
		if (![[arrayController arrangedObjects] containsObject: dir])
			[arrayController addObject: dir];
		else
			NSBeep();
	//	NSLog(@"addDirectory: %@", dir);
	}
}


- (IBAction) addItems: (id) sender
{
	NSArray* const theItems = [arrayController arrangedObjects];
	NSMutableArray* selectedItems = [NSMutableArray array];
	NSEnumerator* en = [[targetBrowser selectedItems] objectEnumerator];
	id it;
	while (it = [en nextObject])
	{
		if (![theItems containsObject: it])
			[selectedItems addObject: it];
	}

	if ([selectedItems count])
		[arrayController addObjects: selectedItems];
	else
		NSBeep();
}


- (IBAction) validate: (id) sender
{
	if ([sender tag] != 0 && [[commitMessage string] length] == 0)
	{
		[svnSheet makeFirstResponder: commitMessage];
		NSBeep();
	}
	else
	{		
		[NSApp endSheet: svnSheet returnCode: [sender tag]];
	}
}


//----------------------------------------------------------------------------------------
#pragma mark	-
#pragma mark	Error sheet

- (void) svnError: (NSString*) errorString
{
	NSAlert* alert = [NSAlert alertWithMessageText: @"Error"
									 defaultButton: @"OK"
								   alternateButton: nil
									   otherButton: nil
						 informativeTextWithFormat: @"%@", errorString];

	[alert setAlertStyle: NSCriticalAlertStyle];
}


//----------------------------------------------------------------------------------------
#pragma mark	-
#pragma mark	Accessors

- (SvnOperation) operation
{
	return svnOperation;
}


@end
