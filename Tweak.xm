#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

#define OT_BUNDLE_ID @"ch.b-eng.tor"

static UIButton *gButton = nil;
static BOOL gBusy = NO;
static volatile int32_t gOKCount = 0;
static volatile int32_t gFailCount = 0;
static volatile int32_t gDoneBatches = 0;
static NSMutableDictionary *gErrs = nil;
static NSString *const kOTLock = @"ot.lock";

static NSString *const kOTCollectJS =
@"(function(){try{"
@"var skip={SCRIPT:1,STYLE:1,NOSCRIPT:1,TEXTAREA:1,CODE:1,PRE:1,INPUT:1,SELECT:1};"
@"var root=document.body||document.documentElement;"
@"var w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,null);"
@"var nodes=[],orig=[],n;"
@"while((n=w.nextNode())){"
@"var p=n.parentNode;if(!p)continue;"
@"if(skip[String(p.nodeName).toUpperCase()])continue;"
@"if(p.isContentEditable)continue;"
@"var t=n.nodeValue;"
@"if(!t||t.trim().length<2||t.length>4500)continue;"
@"if(!/\\p{L}/u.test(t)||/\\p{Script=Arabic}/u.test(t))continue;"
@"nodes.push(n);orig.push(t);"
@"if(nodes.length>=30000)break;"
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
@"return JSON.stringify(orig);"
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
        l.numberOfLines = 0;
        l.font = [UIFont boldSystemFontOfSize:14];
        l.textColor = [UIColor whiteColor];
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
        l.textAlignment = NSTextAlignmentCenter;
        l.layer.cornerRadius = 14;
        l.clipsToBounds = YES;
        CGFloat maxW = win.bounds.size.width - 40;
        CGSize sz = [l sizeThatFits:CGSizeMake(maxW - 28, CGFLOAT_MAX)];
        CGFloat w = MIN(sz.width + 28, maxW);
        CGFloat h = sz.height + 16;
        l.frame = CGRectMake((win.bounds.size.width - w) / 2,
                             win.safeAreaInsets.top + 60, w, h);
        [win addSubview:l];
        [UIView animateWithDuration:0.3 delay:3.5 options:0 animations:^{
            l.alpha = 0;
        } completion:^(BOOL finished) {
            [l removeFromSuperview];
        }];
    });
}

static void OTSetButtonTitle(NSString *title) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [gButton setTitle:title forState:UIControlStateNormal];
    });
}

static void OTFinish(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gBusy = NO;
        gButton.alpha = 1.0;
        [gButton setTitle:@"ترجمة" forState:UIControlStateNormal];
        if (msg.length) OTToast(msg);
    });
}

static void OTResetErrs(void) {
    @synchronized (kOTLock) { gErrs = [NSMutableDictionary dictionary]; }
}

static void OTSetErr(NSString *key, NSString *val) {
    if (!key || !val) return;
    @synchronized (kOTLock) {
        if (!gErrs) gErrs = [NSMutableDictionary dictionary];
        gErrs[key] = val;
    }
}

static NSString *OTErrSummary(void) {
    NSMutableArray *parts = [NSMutableArray array];
    @synchronized (kOTLock) {
        for (NSString *k in @[@"C", @"G"]) {
            NSString *v = gErrs[k];
            if (v) [parts addObject:[NSString stringWithFormat:@"%@:%@", k, v]];
        }
    }
    return parts.count ? [parts componentsJoinedByString:@" "] : @"?";
}

static NSString *OTCodeStr(NSError *err, NSInteger code) {
    if (err) return [NSString stringWithFormat:@"e%ld", (long)err.code];
    return [NSString stringWithFormat:@"%ld", (long)code];
}

static NSString *OTSnippet(NSData *d) {
    if (d.length == 0) return @"empty";
    NSUInteger n = MIN((NSUInteger)40, d.length);
    NSString *s = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, n)]
                                        encoding:NSUTF8StringEncoding];
    if (!s) s = @"bin";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return s;
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
        c.HTTPMaximumConnectionsPerHost = 4;
        c.timeoutIntervalForRequest = 25;
        c.timeoutIntervalForResource = 50;
        c.HTTPAdditionalHeaders = @{
            @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            @"Accept": @"application/json, text/plain, */*"
        };
        s = [NSURLSession sessionWithConfiguration:c];
    });
    return s;
}

static NSString *OTEncode(NSString *text) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [text stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static NSString *OTNorm(NSString *s) {
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    });
    NSString *t = [re stringByReplacingMatchesInString:s options:0
                                                 range:NSMakeRange(0, s.length)
                                          withTemplate:@" "];
    return [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *OTExtractTrans(NSData *d) {
    if (d.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingAllowFragments error:nil];
    if (!obj) return nil;
    NSMutableString *s = [NSMutableString string];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        id sents = ((NSDictionary *)obj)[@"sentences"];
        if ([sents isKindOfClass:[NSArray class]]) {
            for (id seg in (NSArray *)sents) {
                if ([seg isKindOfClass:[NSDictionary class]]) {
                    id tr = ((NSDictionary *)seg)[@"trans"];
                    if ([tr isKindOfClass:[NSString class]]) [s appendString:tr];
                }
            }
        }
    } else if ([obj isKindOfClass:[NSArray class]] && [(NSArray *)obj count] > 0) {
        id first = [(NSArray *)obj objectAtIndex:0];
        if ([first isKindOfClass:[NSString class]]) {
            for (id e in (NSArray *)obj) {
                if ([e isKindOfClass:[NSString class]]) [s appendString:e];
            }
        } else if ([first isKindOfClass:[NSArray class]] && [(NSArray *)first count] > 0) {
            id f0 = [(NSArray *)first objectAtIndex:0];
            if ([f0 isKindOfClass:[NSString class]]) {
                [s appendString:f0];
            } else if ([f0 isKindOfClass:[NSArray class]]) {
                for (id seg in (NSArray *)first) {
                    if ([seg isKindOfClass:[NSArray class]] && [(NSArray *)seg count] > 0) {
                        id t0 = [(NSArray *)seg objectAtIndex:0];
                        if ([t0 isKindOfClass:[NSString class]]) [s appendString:t0];
                    }
                }
            }
        }
    }
    return s.length ? [s copy] : nil;
}

static NSArray<NSString *> *OTSplitByLine(NSString *all, NSUInteger expected) {
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *part in [all componentsSeparatedByString:@"\n"]) {
        NSString *t = [part stringByTrimmingCharactersInSet:ws];
        if (t.length) [out addObject:t];
    }
    return out.count == expected ? out : nil;
}

static NSMutableURLRequest *OTBuildPost(NSUInteger provider, NSString *enc) {
    if (!enc) return nil;
    NSString *u = (provider == 0)
        ? @"https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl=ar"
        : @"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=ar&dt=t";
    NSURL *url = [NSURL URLWithString:u];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:25];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [[@"q=" stringByAppendingString:enc] dataUsingEncoding:NSUTF8StringEncoding];
    return req;
}

static NSData *OTSyncRequest(NSURLRequest *req, NSInteger *codeOut, NSError **errOut) {
    __block NSData *data = nil;
    __block NSInteger code = 0;
    __block NSError *e = nil;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [[OTSession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        data = d;
        e = err;
        code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        dispatch_semaphore_signal(s);
    }] resume];
    dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
    if (codeOut) *codeOut = code;
    if (errOut) *errOut = e;
    return data;
}

static NSString *OTSingleSync(NSString *text) {
    NSString *enc = OTEncode(text);
    if (!enc) return nil;
    NSArray *names = @[@"C", @"G"];
    for (NSUInteger provider = 0; provider < 2; provider++) {
        for (int attempt = 0; attempt < 2; attempt++) {
            NSMutableURLRequest *req = OTBuildPost(provider, enc);
            if (!req) break;
            NSInteger code = 0;
            NSError *err = nil;
            NSData *d = OTSyncRequest(req, &code, &err);
            if (!err && code == 200) {
                NSString *res = OTExtractTrans(d);
                if (res) {
                    return [res stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }
                OTSetErr(names[provider], [NSString stringWithFormat:@"200:%@", OTSnippet(d)]);
                break;
            }
            OTSetErr(names[provider], OTCodeStr(err, code));
            if (code == 429 && attempt == 0) { [NSThread sleepForTimeInterval:1.5]; continue; }
            break;
        }
    }
    return nil;
}

static NSArray<NSString *> *OTBatchTry(NSArray<NSString *> *lines, BOOL *hard, NSInteger *lastCode) {
    *hard = YES;
    *lastCode = 0;
    NSString *joined = [lines componentsJoinedByString:@"\n"];
    NSString *enc = OTEncode(joined);
    if (!enc) return nil;
    NSArray *names = @[@"C", @"G"];
    for (NSUInteger provider = 0; provider < 2; provider++) {
        for (int attempt = 0; attempt < 2; attempt++) {
            NSMutableURLRequest *req = OTBuildPost(provider, enc);
            if (!req) break;
            NSInteger code = 0;
            NSError *err = nil;
            NSData *d = OTSyncRequest(req, &code, &err);
            *lastCode = err ? 0 : code;
            if (!err && code == 200) {
                *hard = NO;
                NSString *all = OTExtractTrans(d);
                NSArray<NSString *> *res = all ? OTSplitByLine(all, lines.count) : nil;
                if (res) return res;
                OTSetErr(names[provider], @"200:split");
                break;
            }
            OTSetErr(names[provider], OTCodeStr(err, code));
            if (code == 429 && attempt == 0) { [NSThread sleepForTimeInterval:1.5]; continue; }
            break;
        }
    }
    return nil;
}

static NSArray *OTTranslateLinesSync(NSArray<NSString *> *lines) {
    if (lines.count == 0) return @[];
    if (lines.count == 1) {
        NSString *one = OTSingleSync(lines[0]);
        return @[one ? (id)one : (id)[NSNull null]];
    }
    BOOL hard = NO;
    NSInteger lastCode = 0;
    NSArray *r = OTBatchTry(lines, &hard, &lastCode);
    if (r) return r;
    if (hard && (lastCode == 429 || lastCode == 403 || lastCode == 0 || lastCode >= 500)) {
        NSMutableArray *nulls = [NSMutableArray arrayWithCapacity:lines.count];
        for (NSUInteger i = 0; i < lines.count; i++) [nulls addObject:[NSNull null]];
        return nulls;
    }
    NSUInteger mid = lines.count / 2;
    NSArray *a = OTTranslateLinesSync([lines subarrayWithRange:NSMakeRange(0, mid)]);
    NSArray *b = OTTranslateLinesSync([lines subarrayWithRange:NSMakeRange(mid, lines.count - mid)]);
    return [a arrayByAddingObjectsFromArray:b];
}

static void OTTranslateWebView(WKWebView *wv) {
    gBusy = YES;
    gButton.alpha = 0.5;
    gOKCount = 0;
    gFailCount = 0;
    gDoneBatches = 0;
    OTResetErrs();
    OTSetButtonTitle(@"0%");
    OTToast(@"جارٍ ترجمة الصفحة كاملة… قد تستغرق الصفحة الكبيرة دقيقة أو أكثر");
    [wv evaluateJavaScript:kOTCollectJS completionHandler:^(id result, NSError *error) {
        NSArray *texts = nil;
        if ([result isKindOfClass:[NSString class]]) {
            NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSArray class]]) texts = obj;
        }
        if (texts.count == 0) { OTFinish(@"لا يوجد نص قابل للترجمة"); return; }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSMutableArray<NSString *> *keys = [NSMutableArray array];
            NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *idxMap = [NSMutableDictionary dictionary];
            NSUInteger eligible = 0;
            for (NSUInteger i = 0; i < texts.count; i++) {
                id t = texts[i];
                if (![t isKindOfClass:[NSString class]]) continue;
                NSString *k = OTNorm(t);
                if (k.length < 2) continue;
                eligible++;
                NSMutableArray<NSNumber *> *arr = idxMap[k];
                if (!arr) {
                    arr = [NSMutableArray array];
                    idxMap[k] = arr;
                    [keys addObject:k];
                }
                [arr addObject:@(i)];
            }

            NSMutableArray<NSArray<NSString *> *> *batches = [NSMutableArray array];
            NSMutableArray<NSString *> *cur = [NSMutableArray array];
            NSUInteger chars = 0;
            for (NSString *k in keys) {
                if (cur.count > 0 && (cur.count >= 25 || chars + k.length > 2000)) {
                    [batches addObject:cur];
                    cur = [NSMutableArray array];
                    chars = 0;
                }
                [cur addObject:k];
                chars += k.length + 1;
            }
            if (cur.count > 0) [batches addObject:cur];
            int32_t totalBatches = (int32_t)batches.count;

            NSMutableDictionary *finalMap = [NSMutableDictionary dictionary];
            dispatch_semaphore_t sem = dispatch_semaphore_create(4);
            dispatch_group_t grp = dispatch_group_create();
            for (NSArray<NSString *> *batch in batches) {
                dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                if (gOKCount == 0 && gFailCount >= 3) {
                    dispatch_semaphore_signal(sem);
                    break;
                }
                dispatch_group_enter(grp);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    NSArray *res = OTTranslateLinesSync(batch);
                    BOOL got = NO;
                    for (NSUInteger i = 0; i < batch.count && i < res.count; i++) {
                        id r = res[i];
                        if (![r isKindOfClass:[NSString class]]) continue;
                        got = YES;
                        @synchronized (finalMap) {
                            for (NSNumber *n in idxMap[batch[i]]) finalMap[[n stringValue]] = r;
                        }
                    }
                    if (got) __sync_fetch_and_add(&gOKCount, 1);
                    else __sync_fetch_and_add(&gFailCount, 1);
                    int32_t done = __sync_add_and_fetch(&gDoneBatches, 1);
                    int pct = totalBatches > 0 ? (int)((int64_t)done * 100 / totalBatches) : 100;
                    OTSetButtonTitle([NSString stringWithFormat:@"%d%%", pct]);
                    dispatch_semaphore_signal(sem);
                    dispatch_group_leave(grp);
                });
            }
            dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);

            NSDictionary *snapshot = nil;
            @synchronized (finalMap) { snapshot = [finalMap copy]; }
            NSUInteger total = snapshot.count;
            if (total == 0) {
                OTFinish([NSString stringWithFormat:@"فشلت الترجمة [%@]", OTErrSummary()]);
                return;
            }

            NSArray *allKeys = [snapshot allKeys];
            NSMutableArray<NSString *> *calls = [NSMutableArray array];
            for (NSUInteger i = 0; i < allKeys.count; i += 500) {
                NSUInteger len = MIN((NSUInteger)500, allKeys.count - i);
                NSMutableDictionary *chunk = [NSMutableDictionary dictionaryWithCapacity:len];
                for (NSUInteger j = i; j < i + len; j++) {
                    chunk[allKeys[j]] = snapshot[allKeys[j]];
                }
                NSData *jd = [NSJSONSerialization dataWithJSONObject:chunk options:0 error:nil];
                NSString *js = jd ? [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding] : nil;
                if (js) [calls addObject:[NSString stringWithFormat:@"window.__otApply(%@)", js]];
            }
            if (calls.count == 0) { OTFinish(@"فشلت الترجمة (JSON)"); return; }

            dispatch_async(dispatch_get_main_queue(), ^{
                __block NSUInteger remaining = calls.count;
                for (NSString *c in calls) {
                    [wv evaluateJavaScript:c completionHandler:^(id r, NSError *e) {
                        remaining--;
                        if (remaining == 0) {
                            if (total < eligible) {
                                OTFinish([NSString stringWithFormat:@"تمت الترجمة جزئيًا (%lu من %lu)",
                                          (unsigned long)total, (unsigned long)eligible]);
                            } else {
                                OTFinish(@"تمت ترجمة الصفحة كاملة");
                            }
                        }
                    }];
                }
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
