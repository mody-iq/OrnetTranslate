#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

#define OT_BUNDLE_ID @"ch.b-eng.tor"

static UIButton *gButton = nil;
static BOOL gBusy = NO;
static volatile int32_t gOKCount = 0;
static volatile int32_t gFailCount = 0;
static volatile int32_t gMSOK = 0;
static volatile int32_t gMSFail = 0;
static NSMutableDictionary *gErrs = nil;
static NSString *gMSToken = nil;
static NSDate *gMSTokenDate = nil;
static NSString *const kOTLock = @"ot.lock";

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
@"if(nodes.length>=400)break;"
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
        [UIView animateWithDuration:0.3 delay:4.0 options:0 animations:^{
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
        for (NSString *k in @[@"T", @"M", @"G", @"C", @"L"]) {
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
        c.timeoutIntervalForRequest = 15;
        c.timeoutIntervalForResource = 30;
        c.HTTPAdditionalHeaders = @{
            @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            @"Accept": @"application/json, text/plain, */*"
        };
        s = [NSURLSession sessionWithConfiguration:c];
    });
    return s;
}

#pragma mark - Microsoft Edge Translate (batched)

static NSString *OTFetchMSToken(void) {
    @synchronized (kOTLock) {
        if (gMSToken && gMSTokenDate && [[NSDate date] timeIntervalSinceDate:gMSTokenDate] < 480) {
            return gMSToken;
        }
    }
    NSURL *url = [NSURL URLWithString:@"https://edge.microsoft.com/translate/auth"];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15];
    req.HTTPMethod = @"GET";
    __block NSString *tok = nil;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [[OTSession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        if (!err && code == 200 && d.length > 20) {
            NSString *t = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length > 20) tok = t;
        }
        if (!tok) OTSetErr(@"T", OTCodeStr(err, code));
        dispatch_semaphore_signal(s);
    }] resume];
    dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
    if (tok) {
        @synchronized (kOTLock) {
            gMSToken = tok;
            gMSTokenDate = [NSDate date];
        }
    }
    return tok;
}

static NSArray<NSString *> *OTMSTranslateBatch(NSArray<NSString *> *batch) {
    if (gMSOK == 0 && gMSFail >= 2) return nil;
    NSString *tok = OTFetchMSToken();
    if (!tok) { __sync_fetch_and_add(&gMSFail, 1); return nil; }

    NSMutableArray *body = [NSMutableArray arrayWithCapacity:batch.count];
    for (NSString *t in batch) [body addObject:@{@"Text": t}];
    NSData *bd = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bd) return nil;

    NSArray *hosts = @[@"https://api-edge.cognitive.microsofttranslator.com",
                       @"https://api.cognitive.microsofttranslator.com"];
    for (NSString *host in hosts) {
        NSURL *url = [NSURL URLWithString:[host stringByAppendingString:@"/translate?to=ar&api-version=3.0&includeSentenceLength=true"]];
        if (!url) continue;
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:20];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[@"Bearer " stringByAppendingString:tok] forHTTPHeaderField:@"Authorization"];
        req.HTTPBody = bd;

        __block NSArray *out = nil;
        __block NSInteger code = 0;
        __block NSError *nerr = nil;
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        [[OTSession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
            nerr = err;
            code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
            if (!err && code == 200 && d.length) {
                id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                if ([obj isKindOfClass:[NSArray class]] && [(NSArray *)obj count] == batch.count) {
                    NSMutableArray *res = [NSMutableArray array];
                    BOOL ok = YES;
                    for (id item in (NSArray *)obj) {
                        NSString *txt = nil;
                        if ([item isKindOfClass:[NSDictionary class]]) {
                            id trs = ((NSDictionary *)item)[@"translations"];
                            if ([trs isKindOfClass:[NSArray class]] && [(NSArray *)trs count] > 0) {
                                id f = [(NSArray *)trs objectAtIndex:0];
                                if ([f isKindOfClass:[NSDictionary class]]) {
                                    id tx = ((NSDictionary *)f)[@"text"];
                                    if ([tx isKindOfClass:[NSString class]]) txt = tx;
                                }
                            }
                        }
                        if (!txt) { ok = NO; break; }
                        [res addObject:txt];
                    }
                    if (ok) out = res;
                }
            }
            dispatch_semaphore_signal(s);
        }] resume];
        dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);

        if (out) { __sync_fetch_and_add(&gMSOK, 1); return out; }
        OTSetErr(@"M", OTCodeStr(nerr, code));
        if (code == 401) {
            @synchronized (kOTLock) { gMSToken = nil; }
            break;
        }
    }
    __sync_fetch_and_add(&gMSFail, 1);
    return nil;
}

#pragma mark - Fallback providers (per text)

static NSString *OTEncode(NSString *text) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [text stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static NSString *OTParseJSON(NSData *d) {
    if (d.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    NSMutableString *s = [NSMutableString string];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        id sents = dict[@"sentences"];
        if ([sents isKindOfClass:[NSArray class]]) {
            for (id seg in (NSArray *)sents) {
                if ([seg isKindOfClass:[NSDictionary class]]) {
                    id tr = ((NSDictionary *)seg)[@"trans"];
                    if ([tr isKindOfClass:[NSString class]]) [s appendString:tr];
                }
            }
        }
        id lt = dict[@"translation"];
        if (s.length == 0 && [lt isKindOfClass:[NSString class]]) [s appendString:lt];
    } else if ([obj isKindOfClass:[NSArray class]] && [(NSArray *)obj count] > 0) {
        id first = [(NSArray *)obj objectAtIndex:0];
        if ([first isKindOfClass:[NSArray class]]) {
            for (id seg in (NSArray *)first) {
                if ([seg isKindOfClass:[NSArray class]] && [(NSArray *)seg count] > 0) {
                    id t0 = [(NSArray *)seg objectAtIndex:0];
                    if ([t0 isKindOfClass:[NSString class]]) [s appendString:t0];
                }
            }
        } else if ([first isKindOfClass:[NSString class]]) {
            [s appendString:first];
        }
    }
    return s.length ? [s copy] : nil;
}

static NSMutableURLRequest *OTBuildRequest(NSUInteger provider, NSString *text) {
    NSString *enc = OTEncode(text);
    if (!enc) return nil;
    NSMutableURLRequest *req = nil;
    if (provider == 0 || provider == 1) {
        NSString *u = (provider == 0)
            ? @"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=ar&dt=t"
            : @"https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl=ar";
        NSURL *url = [NSURL URLWithString:u];
        if (!url) return nil;
        req = [NSMutableURLRequest requestWithURL:url
                                      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                  timeoutInterval:10];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/x-www-form-urlencoded; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [[@"q=" stringByAppendingString:enc] dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        if (text.length > 500) return nil;
        NSURL *url = [NSURL URLWithString:[@"https://lingva.ml/api/v1/auto/ar/" stringByAppendingString:enc]];
        if (!url) return nil;
        req = [NSMutableURLRequest requestWithURL:url
                                      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                  timeoutInterval:10];
        req.HTTPMethod = @"GET";
    }
    return req;
}

static void OTTryProvider(NSUInteger provider, NSString *text, void (^done)(NSString *)) {
    if (provider >= 3) { done(nil); return; }
    NSMutableURLRequest *req = OTBuildRequest(provider, text);
    if (!req) { OTTryProvider(provider + 1, text, done); return; }
    NSArray *names = @[@"G", @"C", @"L"];
    [[OTSession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        NSString *res = (!err && code == 200) ? OTParseJSON(d) : nil;
        if (res) { done(res); return; }
        OTSetErr(names[provider], OTCodeStr(err, code));
        OTTryProvider(provider + 1, text, done);
    }] resume];
}

static void OTTranslateText(NSString *text, void (^done)(NSString *)) {
    if (gOKCount == 0 && gFailCount >= 6) { done(nil); return; }
    OTTryProvider(0, text, ^(NSString *out) {
        if (out) __sync_fetch_and_add(&gOKCount, 1);
        else __sync_fetch_and_add(&gFailCount, 1);
        done(out);
    });
}

#pragma mark - Main translate flow

static void OTTranslateWebView(WKWebView *wv) {
    gBusy = YES;
    gButton.alpha = 0.5;
    gOKCount = 0;
    gFailCount = 0;
    gMSOK = 0;
    gMSFail = 0;
    OTResetErrs();
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
            NSArray<NSString *> *list = [uniq array];
            NSMutableDictionary<NSString *, NSString *> *cache = [NSMutableDictionary dictionary];

            // Phase 1: Microsoft, batched
            const NSUInteger kBatch = 25;
            dispatch_semaphore_t sem1 = dispatch_semaphore_create(3);
            dispatch_group_t grp1 = dispatch_group_create();
            for (NSUInteger i = 0; i < list.count; i += kBatch) {
                NSUInteger len = MIN(kBatch, list.count - i);
                NSArray<NSString *> *sub = [list subarrayWithRange:NSMakeRange(i, len)];
                dispatch_semaphore_wait(sem1, DISPATCH_TIME_FOREVER);
                dispatch_group_enter(grp1);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    NSArray<NSString *> *res = OTMSTranslateBatch(sub);
                    if (res && res.count == sub.count) {
                        @synchronized (cache) {
                            for (NSUInteger j = 0; j < sub.count; j++) cache[sub[j]] = res[j];
                        }
                    }
                    dispatch_semaphore_signal(sem1);
                    dispatch_group_leave(grp1);
                });
            }
            dispatch_group_wait(grp1, DISPATCH_TIME_FOREVER);

            // Phase 2: fallback per text for whatever is still missing
            NSMutableArray<NSString *> *missing = [NSMutableArray array];
            for (NSString *t in list) {
                BOOL has = NO;
                @synchronized (cache) { has = (cache[t] != nil); }
                if (!has) [missing addObject:t];
            }
            if (missing.count > 0) {
                dispatch_semaphore_t sem2 = dispatch_semaphore_create(4);
                dispatch_group_t grp2 = dispatch_group_create();
                for (NSString *t in missing) {
                    dispatch_semaphore_wait(sem2, DISPATCH_TIME_FOREVER);
                    dispatch_group_enter(grp2);
                    OTTranslateText(t, ^(NSString *out) {
                        if (out) { @synchronized (cache) { cache[t] = out; } }
                        dispatch_semaphore_signal(sem2);
                        dispatch_group_leave(grp2);
                    });
                }
                dispatch_group_wait(grp2, DISPATCH_TIME_FOREVER);
            }

            NSMutableDictionary *map = [NSMutableDictionary dictionary];
            for (NSUInteger i = 0; i < texts.count; i++) {
                id t = texts[i];
                if (![t isKindOfClass:[NSString class]]) continue;
                NSString *s = [(NSString *)t stringByTrimmingCharactersInSet:ws];
                NSString *tr = nil;
                @synchronized (cache) { tr = cache[s]; }
                if (tr) map[[NSString stringWithFormat:@"%lu", (unsigned long)i]] = tr;
            }
            if (map.count == 0) {
                OTFinish([NSString stringWithFormat:@"فشلت الترجمة [%@]", OTErrSummary()]);
                return;
            }
            NSData *jd = [NSJSONSerialization dataWithJSONObject:map options:0 error:nil];
            NSString *js = jd ? [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding] : nil;
            if (!js) { OTFinish(@"فشلت الترجمة (JSON)"); return; }
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
