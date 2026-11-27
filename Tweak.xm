#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

#define OT_BUNDLE_ID @"ch.b-eng.tor"

static UIButton *gButton = nil;
static BOOL gBusy = NO;

static NSString *const kOTCollectJS =
@"(function(){try{"
@"var skip={SCRIPT:1,STYLE:1,NOSCRIPT:1,TEXTAREA:1,CODE:1,PRE:1,INPUT:1,SELECT:1};"
@"var root=document.body||document.documentElement;"
@"var w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,null);"
@"var nodes=[],orig=[],texts=[],n;"
@"while((n=w.nextNode())){"
@"var p=n.parentNode;if(!p)continue;"
@"if(skip[String(p.nodeName).toUpperCase()])continue;"
@"if(p.isContentEditable)continue;"
@"var t=n.nodeValue;"
@"if(!t||t.trim().length<2||t.length>1200)continue;"
@"if(!/\\p{L}/u.test(t)||/\\p{Script=Arabic}/u.test(t))continue;"
@"nodes.push(n);orig.push(t);texts.push(t);"
@"if(nodes.length>=600)break;"
@"}"
@"window.__ot={n:nodes,o:orig,on:false};"
@"window.__otApply=function(m){var s=window.__ot;if(!s)return 0;var c=0;"
@"for(var k in m){var i=+k;var x=s.n[i];"
@"if(x&&x.parentNode){var o=s.o[i];var l=o.match(/^\\s*/)[0];var r=o.match(/\\s*$/)[0];"
@"x.nodeValue=l+m[k]+r;c++;}}"
@"s.on=true;return c;};"
@"window.__otRestore=function(){var s=window.__ot;if(!s)return 0;"
@"for(var i=0;i<s.n.length;i++){var x=s.n[i];if(x&&x.parentNode){x.nodeValue=s.o[i];}}"
@"s.on=false;return 1;};"
@"return JSON.stringify(texts);"
@"}catch(e){return '[]';}})()";

@interface OTHelper : NSObject
+ (instancetype)shared;
- (void)tap;
- (void)pan:(UIPanGestureRecognizer *)g;
@end

static UIWindow *OTKeyWindow(void) {
    UIWindow *found = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        if (sc.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) return w;
            if (!found && !w.hidden) found = w;
        }
    }
    return found;
}

static void OTToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = OTKeyWindow();
        if (!win) return;
        UILabel *l = [[UILabel alloc] init];
        l.text = msg;
        l.font = [UIFont boldSystemFontOfSize:14];
        l.textColor = [UIColor whiteColor];
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
        l.textAlignment = NSTextAlignmentCenter;
        l.layer.cornerRadius = 16;
        l.clipsToBounds = YES;
        [l sizeToFit];
        CGRect fr = l.frame;
        fr.size.height = 32;
        fr.size.width = MIN(fr.size.width + 28, win.bounds.size.width - 40);
        fr.origin.x = (win.bounds.size.width - fr.size.width) / 2;
        fr.origin.y = win.safeAreaInsets.top + 60;
        l.frame = fr;
        [win addSubview:l];
        [UIView animateWithDuration:0.3 delay:1.8 options:0 animations:^{
            l.alpha = 0;
        } completion:^(BOOL finished) {
            [l removeFromSuperview];
        }];
    });
}

static void OTFinish(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gBusy = NO;
        gButton.alpha = 1.0;
        if (msg.length) OTToast(msg);
    });
}

static void OTCollectWebViews(UIView *v, NSMutableArray *out) {
    if ([v isKindOfClass:[WKWebView class]]) {
        [out addObject:v];
        return;
    }
    for (UIView *s in v.subviews) OTCollectWebViews(s, out);
}

static WKWebView *OTFindWebView(void) {
    NSMutableArray *all = [NSMutableArray array];
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) OTCollectWebViews(w, all);
    }
    WKWebView *best = nil;
    CGFloat bestArea = 0;
    for (WKWebView *wv in all) {
        if (!wv.window || wv.hidden || wv.alpha < 0.01) continue;
        BOOL hid = NO;
        for (UIView *p = wv.superview; p; p = p.superview) {
            if (p.hidden || p.alpha < 0.01) { hid = YES; break; }
        }
        if (hid) continue;
        CGRect r = CGRectIntersection([wv convertRect:wv.bounds toView:nil], wv.window.bounds);
        if (CGRectIsNull(r)) continue;
        CGFloat a = r.size.width * r.size.height;
        if (a > 0 && a >= bestArea) { best = wv; bestArea = a; }
    }
    return best;
}

static NSURLSession *OTSession(void) {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.HTTPMaximumConnectionsPerHost = 6;
        c.timeoutIntervalForRequest = 15;
        s = [NSURLSession sessionWithConfiguration:c];
    });
    return s;
}

static void OTTranslateText(NSString *text, void (^done)(NSString *)) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *enc = [text stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    if (!enc) { done(nil); return; }
    NSString *u = [NSString stringWithFormat:
        @"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=ar&dt=t&q=%@", enc];
    NSURL *url = [NSURL URLWithString:u];
    if (!url) { done(nil); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15];
    [[OTSession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        NSString *res = nil;
        if (d && !err) {
            id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([obj isKindOfClass:[NSArray class]] && [(NSArray *)obj count] > 0 &&
                [obj[0] isKindOfClass:[NSArray class]]) {
                NSMutableString *s = [NSMutableString string];
                for (id seg in (NSArray *)obj[0]) {
                    if ([seg isKindOfClass:[NSArray class]] && [(NSArray *)seg count] > 0 &&
                        [seg[0] isKindOfClass:[NSString class]]) {
                        [s appendString:seg[0]];
                    }
                }
                if (s.length) res = s;
            }
        }
        done(res);
    }] resume];
}

static void OTTranslateWebView(WKWebView *wv) {
    gBusy = YES;
    gButton.alpha = 0.5;
    OTToast(@"جارٍ الترجمة…");
    [wv evaluateJavaScript:kOTCollectJS completionHandler:^(id result, NSError *error) {
        NSArray *texts = nil;
        if ([result isKindOfClass:[NSString class]]) {
            NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSArray class]]) texts = obj;
        }
        if (texts.count == 0) { OTFinish(@"لا يوجد نص قابل للترجمة"); return; }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
            NSMutableOrderedSet<NSString *> *uniq = [NSMutableOrderedSet orderedSet];
            for (id t in texts) {
                if (![t isKindOfClass:[NSString class]]) continue;
                NSString *s = [(NSString *)t stringByTrimmingCharactersInSet:ws];
                if (s.length) [uniq addObject:s];
            }
            NSMutableDictionary<NSString *, NSString *> *cache = [NSMutableDictionary dictionary];
            dispatch_semaphore_t sem = dispatch_semaphore_create(6);
            dispatch_group_t grp = dispatch_group_create();
            for (NSString *t in uniq) {
                dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                dispatch_group_enter(grp);
                OTTranslateText(t, ^(NSString *out) {
                    if (out) { @synchronized (cache) { cache[t] = out; } }
                    dispatch_semaphore_signal(sem);
                    dispatch_group_leave(grp);
                });
            }
            dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);

            NSMutableDictionary *map = [NSMutableDictionary dictionary];
            for (NSUInteger i = 0; i < texts.count; i++) {
                id t = texts[i];
                if (![t isKindOfClass:[NSString class]]) continue;
                NSString *s = [(NSString *)t stringByTrimmingCharactersInSet:ws];
                NSString *tr = nil;
                @synchronized (cache) { tr = cache[s]; }
                if (tr) map[[NSString stringWithFormat:@"%lu", (unsigned long)i]] = tr;
            }
            if (map.count == 0) { OTFinish(@"فشلت الترجمة، تحقق من الاتصال"); return; }
            NSData *jd = [NSJSONSerialization dataWithJSONObject:map options:0 error:nil];
            NSString *js = jd ? [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding] : nil;
            if (!js) { OTFinish(@"فشلت الترجمة"); return; }
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *call = [NSString stringWithFormat:@"window.__otApply(%@)", js];
                [wv evaluateJavaScript:call completionHandler:^(id r, NSError *e) {
                    OTFinish(e ? @"تعذر تطبيق الترجمة" : @"تمت الترجمة");
                }];
            });
        });
    }];
}

@implementation OTHelper
+ (instancetype)shared {
    static OTHelper *h = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [[OTHelper alloc] init]; });
    return h;
}
- (void)tap {
    if (gBusy) return;
    WKWebView *wv = OTFindWebView();
    if (!wv) { OTToast(@"لم أجد صفحة ويب"); return; }
    [wv evaluateJavaScript:@"(window.__ot&&window.__ot.on)?1:0" completionHandler:^(id r, NSError *e) {
        if ([r isKindOfClass:[NSNumber class]] && [r intValue] == 1) {
            [wv evaluateJavaScript:@"window.__otRestore()" completionHandler:nil];
            OTToast(@"تمت استعادة النص الأصلي");
        } else {
            OTTranslateWebView(wv);
        }
    }];
}
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    UIView *sup = v.superview;
    if (!sup) return;
    CGPoint t = [g translationInView:sup];
    CGPoint c = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    CGFloat hw = v.bounds.size.width / 2, hh = v.bounds.size.height / 2;
    c.x = MAX(hw, MIN(sup.bounds.size.width - hw, c.x));
    c.y = MAX(sup.safeAreaInsets.top + hh, MIN(sup.bounds.size.height - sup.safeAreaInsets.bottom - hh, c.y));
    v.center = c;
    [g setTranslation:CGPointZero inView:sup];
}
@end

static void OTEnsureButton(void) {
    if (![UIApplication sharedApplication]) return;
    UIWindow *win = OTKeyWindow();
    if (!win) return;
    if (!gButton) {
        gButton = [UIButton buttonWithType:UIButtonTypeCustom];
        gButton.frame = CGRectMake(win.bounds.size.width - 70, win.safeAreaInsets.top + 120, 60, 34);
        gButton.backgroundColor = [UIColor colorWithRed:0.35 green:0.20 blue:0.55 alpha:0.92];
        gButton.layer.cornerRadius = 17;
        gButton.clipsToBounds = YES;
        gButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [gButton setTitle:@"ترجمة" forState:UIControlStateNormal];
        [gButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [gButton addTarget:[OTHelper shared] action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[OTHelper shared] action:@selector(pan:)];
        [gButton addGestureRecognizer:pan];
    }
    if (gButton.superview != win) {
        [gButton removeFromSuperview];
        [win addSubview:gButton];
    }
    [win bringSubviewToFront:gButton];
}

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:OT_BUNDLE_ID]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
                OTEnsureButton();
            }];
        });
    }
}
