/*
 Copyright (c) 2011, salesforce.com, inc. All rights reserved.
 
 Redistribution and use of this software in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright notice, this list of conditions
 and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of
 conditions and the following disclaimer in the documentation and/or other materials provided
 with the distribution.
 * Neither the name of salesforce.com, inc. nor the names of its contributors may be used to
 endorse or promote products derived from this software without specific prior written
 permission of salesforce.com, inc.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
 WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <Security/Security.h>
#import "SFOAuthCredentials+Internal.h"
#import "SFOAuthCoordinator+Internal.h"
#import "SFOAuthInfo.h"
#import "SFOAuthOrgAuthConfiguration.h"
#import <SalesforceSecurity/SFSDKCryptoUtils.h>
#import <SalesforceSDKCommon/NSData+SFSDKUtils.h>

// Public constants

const NSTimeInterval kSFOAuthDefaultTimeout                     = 120.0; // seconds
NSString * const     kSFOAuthErrorDomain                        = @"com.salesforce.OAuth.ErrorDomain";

// Private constants

static NSString * const kSFOAuthEndPointAuthorize               = @"/services/oauth2/authorize";    // user agent flow
static NSString * const kSFOAuthEndPointToken                   = @"/services/oauth2/token";        // token refresh flow

// Advanced auth constants
static NSString * const kSFOAuthEndPointAuthConfiguration       = @"/.well-known/auth-configuration";
static NSUInteger const kSFOAuthCodeVerifierByteLength          = 128;
static NSString * const kSFOAuthCodeVerifierParamName           = @"code_verifier";
static NSString * const kSFOAuthCodeChallengeParamName          = @"code_challenge";
static NSString * const kSFOAuthResponseTypeCode                = @"code";

static NSString * const kSFOAuthAccessToken                     = @"access_token";
static NSString * const kSFOAuthClientId                        = @"client_id";
static NSString * const kSFOAuthCustomPermissions               = @"custom_permissions";
static NSString * const kSFOAuthDisplay                         = @"display";
static NSString * const kSFOAuthDisplayTouch                    = @"touch";
static NSString * const kSFOAuthError                           = @"error";
static NSString * const kSFOAuthErrorDescription                = @"error_description";
static NSString * const kSFOAuthFormat                          = @"format";
static NSString * const kSFOAuthFormatJson                      = @"json";
static NSString * const kSFOAuthGrantType                       = @"grant_type";
static NSString * const kSFOAuthGrantTypeRefreshToken           = @"refresh_token";
static NSString * const kSFOAuthId                              = @"id";
static NSString * const kSFOAuthInstanceUrl                     = @"instance_url";
static NSString * const kSFOAuthCommunityId                     = @"sfdc_community_id";
static NSString * const kSFOAuthCommunityUrl                    = @"sfdc_community_url";
static NSString * const kSFOAuthIssuedAt                        = @"issued_at";
static NSString * const kSFOAuthRedirectUri                     = @"redirect_uri";
static NSString * const kSFOAuthRefreshToken                    = @"refresh_token";
static NSString * const kSFOAuthResponseType                    = @"response_type";
static NSString * const kSFOAuthResponseTypeToken               = @"token";
static NSString * const kSFOAuthScope                           = @"scope";
static NSString * const kSFOAuthSignature                       = @"signature";

// Used for the IP bypass flow, Advanced auth flow
static NSString * const kSFOAuthApprovalCode                    = @"code";
static NSString * const kSFOAuthGrantTypeAuthorizationCode      = @"authorization_code";
static NSString * const kSFOAuthResponseTypeActivatedClientCode = @"activated_client_code";
static NSString * const kSFOAuthResponseClientSecret            = @"client_secret";
static NSString * const kSFOAuthClientSecretAnonymous           = @"anonymous";

// OAuth Error Descriptions
// see https://na1.salesforce.com/help/doc/en/remoteaccess_oauth_refresh_token_flow.htm

static NSString * const kSFOAuthErrorTypeMalformedResponse          = @"malformed_response";
static NSString * const kSFOAuthErrorTypeAccessDenied               = @"access_denied";
static NSString * const KSFOAuthErrorTypeInvalidClientId            = @"invalid_client_id"; // invalid_client_id:'client identifier invalid'
                                                                                            // this may be returned when the refresh token is revoked
                                                                                            // TODO: needs clarification
static NSString * const kSFOAuthErrorTypeInvalidClient              = @"invalid_client";    // invalid_client:'invalid client credentials'
                                                                                            // this is returned when refresh token is revoked
static NSString * const kSFOAuthErrorTypeInvalidClientCredentials   = @"invalid_client_credentials"; // this is documented but hasn't been witnessed
static NSString * const kSFOAuthErrorTypeInvalidGrant               = @"invalid_grant";
static NSString * const kSFOAuthErrorTypeInvalidRequest             = @"invalid_request";
static NSString * const kSFOAuthErrorTypeInactiveUser               = @"inactive_user";
static NSString * const kSFOAuthErrorTypeInactiveOrg                = @"inactive_org";
static NSString * const kSFOAuthErrorTypeRateLimitExceeded          = @"rate_limit_exceeded";
static NSString * const kSFOAuthErrorTypeUnsupportedResponseType    = @"unsupported_response_type";
static NSString * const kSFOAuthErrorTypeTimeout                    = @"auth_timeout";
static NSString * const kSFOAuthErrorTypeWrongVersion               = @"wrong_version";     // credentials do not match current Connected App version in the org
static NSString * const kSFOAuthErrorTypeBrowserLaunchFailed        = @"browser_launch_failed";
static NSString * const kSFOAuthErrorTypeUnknownAdvancedAuthConfig  = @"unknown_advanced_auth_config";

static NSUInteger kSFOAuthReponseBufferLength                   = 512; // bytes

static NSString * const kHttpMethodPost                         = @"POST";
static NSString * const kHttpHeaderContentType                  = @"Content-Type";
static NSString * const kHttpPostContentType                    = @"application/x-www-form-urlencoded";

@implementation SFOAuthCoordinator

@synthesize credentials          = _credentials;
@synthesize delegate             = _delegate;
@synthesize timeout              = _timeout;
@synthesize view                 = _view;

// private

@synthesize authenticating              = _authenticating;
@synthesize connection                  = _connection;
@synthesize responseData                = _responseData;
@synthesize initialRequestLoaded        = _initialRequestLoaded;
@synthesize approvalCode                = _approvalCode;
@synthesize scopes                      = _scopes;
@synthesize refreshFlowConnectionTimer  = _refreshFlowConnectionTimer;
@synthesize refreshTimerThread          = _refreshTimerThread;
@synthesize advancedAuthConfiguration   = _advancedAuthConfiguration;
@synthesize advancedAuthState           = _advancedAuthState;
@synthesize codeVerifier                = _codeVerifier;
@synthesize authInfo                    = _authInfo;
@synthesize oauthCoordinatorFlow        = _oauthCoordinatorFlow;


- (id)init {
    return [self initWithCredentials:nil];
}

- (id)initWithCredentials:(SFOAuthCredentials *)credentials {
    self = [super init];
    if (self) {
        self.oauthCoordinatorFlow = self;
        self.credentials = credentials;
        self.authenticating = NO;
        _timeout = kSFOAuthDefaultTimeout;
        _view = nil;
    }
    
    // response data is initialized in didReceiveResponse
    
    return self;
}

- (void)dealloc {
    _approvalCode = nil;
    _connection = nil;
    _credentials = nil;
    _responseData = nil;
    _scopes = nil;
    [self stopRefreshFlowConnectionTimer];
    _view.delegate = nil;
    _view = nil;
}

- (void)authenticate {
    NSAssert(nil != self.credentials, @"credentials cannot be nil");
    NSAssert([self.credentials.clientId length] > 0, @"credentials.clientId cannot be nil or empty");
    NSAssert([self.credentials.identifier length] > 0, @"credentials.identifier cannot be nil or empty");
    NSAssert(nil != self.delegate, @"cannot authenticate with nil delegate");
    
    if (self.authenticating) {
        [self log:SFLogLevelDebug format:@"%@ Error: authenticate called while already authenticating. Call stopAuthenticating first.", NSStringFromSelector(_cmd)];
        return;
    }
    if (self.credentials.logLevel < kSFOAuthLogLevelWarning) {
        [self log:SFLogLevelDebug format:@"%@ authenticating as %@ %@ refresh token on '%@://%@' ...",
         NSStringFromSelector(_cmd),
         self.credentials.clientId, (nil == self.credentials.refreshToken ? @"without" : @"with"),
         self.credentials.protocol, self.credentials.domain];
    }
    
    self.authenticating = YES;
    
    if (self.credentials.refreshToken) {
        self.authInfo = [[SFOAuthInfo alloc] initWithAuthType:SFOAuthTypeRefresh];
    } else {
        self.authInfo = [[SFOAuthInfo alloc] initWithAuthType:SFOAuthTypeUserAgent];
    }
    
    // Don't try to authenticate if there is no network available
    if ([self.delegate respondsToSelector:@selector(oauthCoordinatorIsNetworkAvailable:)] &&
        ![self.delegate oauthCoordinatorIsNetworkAvailable:self]) {
        [self log:SFLogLevelDebug msg:@"Network is not available, so bypassing login"];
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
        [self notifyDelegateOfFailure:error authInfo:self.authInfo];
        return;
    }
    
    if (self.credentials.refreshToken) {
        // clear any access token we may have and begin refresh flow
        [self notifyDelegateOfBeginAuthentication];
        [self.oauthCoordinatorFlow beginTokenEndpointFlow:SFOAuthTokenEndpointFlowRefresh];
    } else {
        switch (self.advancedAuthConfiguration) {
            case SFOAuthAdvancedAuthConfigurationNone: {
                [self notifyDelegateOfBeginAuthentication];
                [self.oauthCoordinatorFlow beginUserAgentFlow];
                break;
            }
            case SFOAuthAdvancedAuthConfigurationAllow: {
                __weak SFOAuthCoordinator *weakSelf = self;
                // If advanced auth mode is allowed, we have to get auth configuration settings from the org, where
                // available, and initiate advanced auth flows, if configured.
                [self.oauthCoordinatorFlow retrieveOrgAuthConfiguration:^(SFOAuthOrgAuthConfiguration *orgAuthConfig, NSError *error) {
                    if (error) {
                        // That's fatal.
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf notifyDelegateOfFailure:error authInfo:self.authInfo];
                        });
                    } else if (orgAuthConfig.useNativeBrowserForAuth) {
                        weakSelf.authInfo = [[SFOAuthInfo alloc] initWithAuthType:SFOAuthTypeAdvancedBrowser];
                        [weakSelf notifyDelegateOfBeginAuthentication];
                        [weakSelf.oauthCoordinatorFlow beginNativeBrowserFlow];
                    } else {
                        [self notifyDelegateOfBeginAuthentication];
                        [weakSelf.oauthCoordinatorFlow beginUserAgentFlow];
                    }
                }];
                break;
            }
            case SFOAuthAdvancedAuthConfigurationRequire: {
                // Advanced auth mode is required.  Begin the advanced browser flow.
                self.authInfo = [[SFOAuthInfo alloc] initWithAuthType:SFOAuthTypeAdvancedBrowser];
                [self notifyDelegateOfBeginAuthentication];
                [self.oauthCoordinatorFlow beginNativeBrowserFlow];
                break;
            }
            default: {
                // Unknown advanced auth state.
                NSError *unknownConfigError = [[self class] errorWithType:kSFOAuthErrorTypeUnknownAdvancedAuthConfig
                                                              description:[NSString stringWithFormat:@"Unknown advanced auth config: %lu", (unsigned long)self.advancedAuthConfiguration]];
                [self notifyDelegateOfFailure:unknownConfigError authInfo:self.authInfo];
                break;
            }
        }
        
    }
}

- (void)authenticateWithCredentials:(SFOAuthCredentials *)credentials {
    self.credentials = credentials;
    [self authenticate];
}

- (BOOL)isAuthenticating {
    return self.authenticating;
}

- (void)stopAuthentication {
    [self.view stopLoading];
    [self.connection cancel];
    self.connection = nil;
    [self stopRefreshFlowConnectionTimer];
    self.authenticating = NO;
}

- (void)revokeAuthentication {
    [self stopAuthentication];
    [self.credentials revoke];
}

- (BOOL)handleAdvancedAuthenticationResponse:(NSURL *)appUrlResponse {
    if (self.advancedAuthState != SFOAuthAdvancedAuthStateBrowserRequestInitiated) {
        [self log:SFLogLevelInfo format:@"%@ Current advanced auth state (%@) not compatible with handling app launch auth response.", NSStringFromSelector(_cmd), [[self class] advancedAuthStateDesc:self.advancedAuthState]];
        return NO;
    }
    
    NSString *appUrlResponseString = [appUrlResponse absoluteString];
    if (![[appUrlResponseString lowercaseString] hasPrefix:[self.credentials.redirectUri lowercaseString]]) {
        [self log:SFLogLevelInfo format:@"%@ URL does not match redirect URI.", NSStringFromSelector(_cmd)];
        return NO;
    }
    
    NSString *query = [appUrlResponse query];
    if ([query length] == 0) {
        [self log:SFLogLevelInfo format:@"%@ URL has no query string.", NSStringFromSelector(_cmd)];
        return NO;
    }
    
    NSDictionary *queryDict = [[self class] parseQueryString:query decodeParams:NO];
    NSString *codeVal = queryDict[kSFOAuthResponseTypeCode];
    if ([codeVal length] == 0) {
        [self log:SFLogLevelInfo format:@"%@ URL has no '%@' parameter value.", NSStringFromSelector(_cmd), kSFOAuthResponseTypeCode];
        return NO;
    }
    
    self.approvalCode = codeVal;
    [self log:SFLogLevelInfo format:@"%@ Received advanced authentication response.  Beginning token exchange.", NSStringFromSelector(_cmd)];
    self.advancedAuthState = SFOAuthAdvancedAuthStateTokenRequestInitiated;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.oauthCoordinatorFlow beginTokenEndpointFlow:SFOAuthTokenEndpointFlowAdvancedBrowser];
    });
    return YES;
}

#pragma mark - Private Methods

- (void)notifyDelegateOfFailure:(NSError*)error authInfo:(SFOAuthInfo *)info
{
    self.authenticating = NO;
    self.advancedAuthState = SFOAuthAdvancedAuthStateNotStarted;
    if ([self.delegate respondsToSelector:@selector(oauthCoordinator:didFailWithError:authInfo:)]) {
        [self.delegate oauthCoordinator:self didFailWithError:error authInfo:info];
    } else if ([self.delegate respondsToSelector:@selector(oauthCoordinator:didFailWithError:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [self.delegate oauthCoordinator:self didFailWithError:error];
#pragma clang diagnostic pop
    }
    self.authInfo = nil;
}

- (void)notifyDelegateOfSuccess:(SFOAuthInfo *)authInfo
{
    self.authenticating = NO;
    self.advancedAuthState = SFOAuthAdvancedAuthStateNotStarted;
    if ([self.delegate respondsToSelector:@selector(oauthCoordinatorDidAuthenticate:authInfo:)]) {
        [self.delegate oauthCoordinatorDidAuthenticate:self authInfo:authInfo];
    } else if ([self.delegate respondsToSelector:@selector(oauthCoordinatorDidAuthenticate:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [self.delegate oauthCoordinatorDidAuthenticate:self];
#pragma clang diagnostic pop
    }
    self.authInfo = nil;
}

- (void)notifyDelegateOfBeginAuthentication
{
    if ([self.delegate respondsToSelector:@selector(oauthCoordinatorWillBeginAuthentication:authInfo:)]) {
        [self.delegate oauthCoordinatorWillBeginAuthentication:self authInfo:self.authInfo];
    }
}

- (void)retrieveOrgAuthConfiguration:(void (^)(SFOAuthOrgAuthConfiguration *, NSError *))retrievedAuthConfigBlock {
    // NB: The second (error) parameter of retrievedAuthConfigCallback is only populated if a fatal error
    // is detected in the process.  Otherwise, errors are considered as no org auth configuration being available.
    
    NSString *orgConfigUrl = [NSString stringWithFormat:@"%@://%@%@",
                              self.credentials.protocol,
                              self.credentials.domain,
                              kSFOAuthEndPointAuthConfiguration
                              ];
    [self log:SFLogLevelInfo format:@"%@ Advanced authentication configured.  Retrieving auth configuration from %@", NSStringFromSelector(_cmd), orgConfigUrl];
    NSMutableURLRequest *orgConfigRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:orgConfigUrl]
                                                                    cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                                timeoutInterval:self.timeout];
    orgConfigRequest.HTTPShouldHandleCookies = NO;
    [NSURLConnection sendAsynchronousRequest:orgConfigRequest
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
                               if (connectionError) {
                                   [self log:SFLogLevelError format:@"%@ Error retrieving org auth config: %@", NSStringFromSelector(_cmd), [connectionError localizedDescription]];
                                   if (retrievedAuthConfigBlock != NULL) {
                                       retrievedAuthConfigBlock(nil, connectionError);
                                       return;
                                   }
                               }
                               
                               NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                               if (httpResponse.statusCode != 200) {
                                   // Anything other than a 200 means we didn't get data back, which means advanced
                                   // auth isn't supported for any orgs on that login host.
                                   [self log:SFLogLevelInfo format:@"%@ No org auth config found at %@ (Status code: %ld)", NSStringFromSelector(_cmd), orgConfigUrl, httpResponse.statusCode];
                                   if (retrievedAuthConfigBlock != NULL) {
                                       retrievedAuthConfigBlock(nil, nil);
                                   }
                                   return;
                               }
                               
                               if (data == nil) {
                                   [self log:SFLogLevelInfo format:@"%@ No org auth config data returned from %@", NSStringFromSelector(_cmd), orgConfigUrl];
                                   if (retrievedAuthConfigBlock != NULL) {
                                       retrievedAuthConfigBlock(nil, nil);
                                       return;
                                   }
                               }
                               
                               NSError *jsonParseError = nil;
                               NSDictionary *configDict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonParseError];
                               if (jsonParseError) {
                                   [self log:SFLogLevelInfo format:@"%@ Could not parse org auth config response from %@: %@", NSStringFromSelector(_cmd), orgConfigUrl, [jsonParseError localizedDescription]];
                                   if (retrievedAuthConfigBlock != NULL) {
                                       retrievedAuthConfigBlock(nil, nil);
                                   }
                               }
                               
                               [self log:SFLogLevelInfo format:@"%@ Successfully retrieved org auth config data from %@", NSStringFromSelector(_cmd), orgConfigUrl];
                               SFOAuthOrgAuthConfiguration *orgAuthConfig = [[SFOAuthOrgAuthConfiguration alloc] initWithConfigDict:configDict];
                               if (retrievedAuthConfigBlock != NULL) {
                                   retrievedAuthConfigBlock(orgAuthConfig, nil);
                               }
                           }];
}

- (void)beginNativeBrowserFlow {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self beginNativeBrowserFlow];
        });
        return;
    }
    
    // E.g. https://login.salesforce.com/services/oauth2/authorize
    //      ?client_id=<Connected App ID>&redirect_uri=<Connected App Redirect URI>&display=touch
    //      &response_type=code
    NSMutableString *approvalUrl = [[NSMutableString alloc] initWithFormat:@"%@://%@%@?%@=%@&%@=%@&%@=%@&%@=%@",
                                    self.credentials.protocol, self.credentials.domain, kSFOAuthEndPointAuthorize,
                                    kSFOAuthClientId, self.credentials.clientId,
                                    kSFOAuthRedirectUri, self.credentials.redirectUri,
                                    kSFOAuthDisplay, kSFOAuthDisplayTouch,
                                    kSFOAuthResponseType, kSFOAuthResponseTypeCode];
    
    // OAuth scopes
    NSString *scopeString = [self scopeQueryParamString];
    if (scopeString != nil) {
        [approvalUrl appendString:scopeString];
    }
    
    // Code verifier challenge:
    //   - self.codeVerifier is a base64url-encoded random data string
    //   - The code challenge sent here is an SHA-256 hash of self.codeVerifier, also base64url-encoded
    //   - Later, self.codeVerifier will be sent to the service, to be used to compare against the initial code challenge sent here.
    self.codeVerifier = [[SFSDKCryptoUtils randomByteDataWithLength:kSFOAuthCodeVerifierByteLength] msdkBase64UrlString];
    NSString *codeChallengeString = [[[self.codeVerifier dataUsingEncoding:NSUTF8StringEncoding] msdkSha256Data] msdkBase64UrlString];
    [approvalUrl appendFormat:@"&%@=%@", kSFOAuthCodeChallengeParamName, codeChallengeString];
    
    // Launch the native browser.
    [self log:SFLogLevelDebug format:@"%@: Initiating native browser flow with URL %@", NSStringFromSelector(_cmd), approvalUrl];
    NSURL *nativeBrowserUrl = [NSURL URLWithString:approvalUrl];
    BOOL browserOpenSucceeded = [[UIApplication sharedApplication] openURL:nativeBrowserUrl];
    if (!browserOpenSucceeded) {
        [self log:SFLogLevelError format:@"%@: Could not launch native browser with URL %@", NSStringFromSelector(_cmd), approvalUrl];
        NSError *launchError = [[self class] errorWithType:kSFOAuthErrorTypeBrowserLaunchFailed description:@"The native browser failed to launch for advanced authentication."];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self notifyDelegateOfFailure:launchError authInfo:self.authInfo];
        });
    } else {
        self.advancedAuthState = SFOAuthAdvancedAuthStateBrowserRequestInitiated;
    }
}

- (void)beginUserAgentFlow {
    
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self beginUserAgentFlow];
        });
        return;
    }
    
    if (nil == self.view) {
        // lazily create web view if needed
        self.view = [[UIWebView  alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    }
    self.view.delegate = self;

    // Ensure that the webview options match how our app wants to handle detected links
    self.view.dataDetectorTypes = UIDataDetectorTypeNone;

    self.initialRequestLoaded = NO;
    
    // notify delegate will be begin authentication in our (web) vew
    if ([self.delegate respondsToSelector:@selector(oauthCoordinator:willBeginAuthenticationWithView:)]) {
        [self.delegate oauthCoordinator:self willBeginAuthenticationWithView:self.view];
    }
    
    // optional query params: 
    //     state - opaque state value to be passed back
    //     immediate - determines whether the user should be prompted for login and approval (default false)
    
    NSAssert(nil != self.credentials.domain, @"credentials.domain is required");
    NSAssert(nil != self.credentials.clientId, @"credentials.clientId is required");
    NSAssert(nil != self.credentials.redirectUri, @"credentials.redirectUri is required");

    NSMutableString *approvalUrl = [[NSMutableString alloc] initWithFormat:@"%@://%@%@?%@=%@&%@=%@&%@=%@",
                                    self.credentials.protocol, self.credentials.domain, kSFOAuthEndPointAuthorize,
                                    kSFOAuthClientId, self.credentials.clientId,
                                    kSFOAuthRedirectUri, self.credentials.redirectUri,
                                    kSFOAuthDisplay, kSFOAuthDisplayTouch];

    // If an activation code is available (IP bypass flow), then use the "activated client" response type.
    if (self.credentials.activationCode) {
        [approvalUrl appendFormat:@"&%@=%@", kSFOAuthResponseType, kSFOAuthResponseTypeActivatedClientCode];
    } else {
        [approvalUrl appendFormat:@"&%@=%@", kSFOAuthResponseType, kSFOAuthResponseTypeToken];        
    }
        
    NSString *scopeString = [self scopeQueryParamString];
    if (scopeString != nil) {
        [approvalUrl appendString:scopeString];
    }
    
    if (self.credentials.logLevel < kSFOAuthLogLevelInfo) {
        [self log:SFLogLevelDebug format:@"SFOAuthCoordinator:beginUserAgentFlow with %@", approvalUrl];
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:approvalUrl]];
	[request setHTTPShouldHandleCookies:NO]; // don't use shared cookies
    [request setCachePolicy:NSURLCacheStorageNotAllowed]; // don't use cache
	
	[self.view loadRequest:request];
}

- (void)beginTokenEndpointFlow:(SFOAuthTokenEndpointFlow)flowType {
    
    self.responseData = [NSMutableData dataWithLength:512];
    NSString *url = [[NSString alloc] initWithFormat:@"%@://%@%@", 
                                                     self.credentials.protocol, 
                                                     self.credentials.domain, 
                                                     kSFOAuthEndPointToken];
	
	NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:url] 
                                                                cachePolicy:NSURLRequestReloadIgnoringCacheData 
                                                            timeoutInterval:self.timeout];
	[request setHTTPMethod:kHttpMethodPost];
	[request setValue:kHttpPostContentType forHTTPHeaderField:kHttpHeaderContentType];
    [request setHTTPShouldHandleCookies:NO];
    
    NSMutableString *params = [[NSMutableString alloc] initWithFormat:@"%@=%@&%@=%@&%@=%@",
                                                                      kSFOAuthFormat, kSFOAuthFormatJson,
                                                                      kSFOAuthRedirectUri, self.credentials.redirectUri,
                                                                      kSFOAuthClientId, self.credentials.clientId];
    NSMutableString *logString = [NSMutableString stringWithString:params];
    
    // If an activation code is available (IP bypass flow), then provide the activation code in the request
    if (self.credentials.activationCode) {
        [params appendFormat:@"&%@=%@", kSFOAuthResponseClientSecret, self.credentials.activationCode];
    }

    // If there is an approval code (IP bypass flow or Advanced Auth flow), use it once to get the tokens.
    if (self.approvalCode) {
        [self log:SFLogLevelInfo format:@"%@: Initiating authorization code flow.", NSStringFromSelector(_cmd)];
        [params appendFormat:@"&%@=%@&%@=%@", kSFOAuthGrantType, kSFOAuthGrantTypeAuthorizationCode, kSFOAuthApprovalCode, self.approvalCode];
        [logString appendFormat:@"&%@=%@&%@=REDACTED", kSFOAuthGrantType, kSFOAuthGrantTypeAuthorizationCode, kSFOAuthApprovalCode];
        
        // If this is the advanced authentication flow, we need to add the code verifier parameter and some form
        // of a client secret as well.
        // TODO: This does not currently work with an anonymous client secret.  WIP from the service side.  Plug in real client secret to test.
        if (self.authInfo.authType == SFOAuthTypeAdvancedBrowser) {
            [params appendFormat:@"&%@=%@", kSFOAuthCodeVerifierParamName, self.codeVerifier];
            [logString appendFormat:@"&%@=REDACTED", kSFOAuthCodeVerifierParamName];
            [params appendFormat:@"&%@=%@", kSFOAuthResponseClientSecret, kSFOAuthClientSecretAnonymous];
        }
        
        // Discard the approval code.
        self.approvalCode = nil;
    } else {
        // Assume Refresh token flow.
        [self log:SFLogLevelInfo format:@"%@: Initiating refresh token flow.", NSStringFromSelector(_cmd)];
        [params appendFormat:@"&%@=%@&%@=%@", kSFOAuthGrantType, kSFOAuthGrantTypeRefreshToken, kSFOAuthRefreshToken, self.credentials.refreshToken];
        [logString appendFormat:@"&%@=%@&%@=REDACTED", kSFOAuthGrantType, kSFOAuthGrantTypeRefreshToken, kSFOAuthRefreshToken];
    }
	
    if (self.credentials.logLevel < kSFOAuthLogLevelInfo) {
        [self log:SFLogLevelDebug format:@"%@ with %@", NSStringFromSelector(_cmd), logString];
    }

	NSData *encodedBody = [params dataUsingEncoding:NSUTF8StringEncoding];
	[request setHTTPBody:encodedBody];
    
    // We set the timeout value for NSMutableURLRequest above, but NSMutableURLRequest has its own ideas
    // about managing the timeout value (see https://devforums.apple.com/thread/25282).  So we manage
    // the timeout with an NSTimer, which gets started here.
    [self startRefreshFlowConnectionTimer];
    
	NSURLConnection *urlConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
    self.connection = urlConnection;
}

/* Handle a 'token' endpoint (e.g. refresh, advanced auth) response.
    Example response:
    { "id":"https://login.salesforce.com/id/00DD0000000FH54SBH/005D0000001GZXmIAO",
      "issued_at":"1309481030001",
      "instance_url":"https://na1.salesforce.com",
      "signature":"YEguoQhgIvJ3apLALB93vRsq/pUxwG2klsyHp9zX9Wg=",
      "access_token":"00DD0000000FH84!AQwAQKS7WDhWO9k6YrhbiWBZiDAZC5RzN2dpleOKGKf5dFsatyAN8kck7mtrNvxRGIgN.wE.Z0ZN_No7h6HNqrq828nL6E2J" }
    
    Example error response:
        { "error":"invalid_grant","error_description":"authentication failure - Invalid Password" }
 */
- (void)handleTokenEndpointResponse {
    [self stopRefreshFlowConnectionTimer];
    
    NSString *responseString = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
    NSError *jsonError = nil;
    id json = nil;

    json = [NSJSONSerialization JSONObjectWithData:self.responseData options:0 error:&jsonError];
    if (nil == jsonError && [json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)json;
        if (nil != dict[kSFOAuthError]) {
            NSError *error = [[self class] errorWithType:dict[kSFOAuthError] description:dict[kSFOAuthErrorDescription]];
            [self notifyDelegateOfFailure:error authInfo:self.authInfo];
        } else {
            if (dict[kSFOAuthRefreshToken]) {
                // Refresh token is available. This happens when the IP bypass flow is used.
                self.credentials.refreshToken = dict[kSFOAuthRefreshToken];
            } else {
                // In a non-IP flow, we already have the refresh token here.
            }

            [self updateCredentials:dict forTokenRefresh:(self.authInfo.authType == SFOAuthTypeRefresh)];
            
            [self notifyDelegateOfSuccess:self.authInfo];
        }
    } else {
        // failed to parse JSON
        [self log:SFLogLevelDebug format:@"%@: JSON parse error: %@", NSStringFromSelector(_cmd), jsonError];
        NSError *error = [[self class] errorWithType:kSFOAuthErrorTypeMalformedResponse description:@"failed to parse response JSON"];
        NSMutableDictionary *errorDict = [NSMutableDictionary dictionaryWithDictionary:jsonError.userInfo];
        if (responseString) {
            errorDict[@"response_data"] = responseString;
        }
        if (error) {
            errorDict[NSUnderlyingErrorKey] = error;
        }
        NSError *finalError = [NSError errorWithDomain:kSFOAuthErrorDomain code:error.code userInfo:errorDict];
        [self notifyDelegateOfFailure:finalError authInfo:self.authInfo];
    }
}

- (void)handleUserAgentResponse:(NSURL *)requestUrl {
    
    NSString *response = nil;
    
    // Check for a response in the URL fragment first, then fall back to the query string.
    if ([requestUrl fragment]) {
        response = [requestUrl fragment];
    } else if ([requestUrl query]) {
        response = [requestUrl query];
    } else {
        [self log:SFLogLevelDebug format:@"%@ Error: response has no payload: %@", NSStringFromSelector(_cmd), requestUrl];
        
        NSError *error = [[self class] errorWithType:kSFOAuthErrorTypeMalformedResponse description:@"redirect response has no payload"];
        [self notifyDelegateOfFailure:error authInfo:self.authInfo];
        response = nil;
    }
    
    if (response) {
        NSDictionary *params = [[self class] parseQueryString:response];
        NSString *error = params[kSFOAuthError];
        if (nil == error) {
            [self updateCredentials:params forTokenRefresh:NO];
            
            self.credentials.refreshToken   = params[kSFOAuthRefreshToken];
            
            self.approvalCode = params[kSFOAuthApprovalCode];
            if (self.approvalCode) {
                // If there is an approval code, then proceed to get the access/refresh token (IP bypass flow).
                [self.oauthCoordinatorFlow beginTokenEndpointFlow:SFOAuthTokenEndpointFlowIPBypass];
            } else {
                // Otherwise, we are done with the authentication.
                [self notifyDelegateOfSuccess:self.authInfo];
            }
        } else {
            NSError *finalError;
            NSError *error = [[self class] errorWithType:params[kSFOAuthError]
                                             description:params[kSFOAuthErrorDescription]];
            
            // add any additional relevant info to the userInfo dictionary
            
            if (kSFOAuthErrorInvalidClientId == error.code) {
                NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:error.userInfo];
                dict[kSFOAuthClientId] = self.credentials.clientId;
                finalError = [NSError errorWithDomain:error.domain code:error.code userInfo:dict];
            } else {
                finalError = error;
            }
            [self notifyDelegateOfFailure:finalError authInfo:self.authInfo];
        }
    }
}

- (NSString *)scopeQueryParamString
{
    NSMutableSet *scopes = (self.scopes.count > 0 ? [NSMutableSet setWithSet:self.scopes] : [NSMutableSet set]);
    [scopes addObject:kSFOAuthRefreshToken];
    NSString *scopeStr = [[[scopes allObjects] componentsJoinedByString:@" "] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"&%@=%@", kSFOAuthScope, scopeStr];
}

/** Update the credentials using the provided oauth parameters.
 This method only update the following parameters:
 - identityUrl
 - accessToken
 - instanceUrl
 - issuedAt
 - communityId
 - communityUrl
 */

- (void)updateCredentials:(NSDictionary*)params forTokenRefresh:(BOOL)tokenRefresh
{
    self.credentials.accessToken    = [params objectForKey:kSFOAuthAccessToken];
    self.credentials.issuedAt       = [[self class] timestampStringToDate:[params objectForKey:kSFOAuthIssuedAt]];
    
    if (!tokenRefresh) {
        self.credentials.instanceUrl    = [NSURL URLWithString:[params objectForKey:kSFOAuthInstanceUrl]];
        self.credentials.identityUrl    = [NSURL URLWithString:[params objectForKey:kSFOAuthId]];
        
        NSString *communityId = [params objectForKey:kSFOAuthCommunityId];
        if (nil != communityId) {
            self.credentials.communityId = communityId;
        }
        
        NSString *communityUrl = [params objectForKey:kSFOAuthCommunityUrl];
        if (nil != communityUrl) {
            self.credentials.communityUrl = [NSURL URLWithString:communityUrl];
        }
    }
}

- (void)startRefreshFlowConnectionTimer
{
    self.refreshTimerThread = [NSThread currentThread];
    self.refreshFlowConnectionTimer = [NSTimer scheduledTimerWithTimeInterval:self.timeout
                                                                       target:self
                                                                     selector:@selector(refreshFlowConnectionTimerFired:)
                                                                     userInfo:nil
                                                                      repeats:NO];
}

- (void)stopRefreshFlowConnectionTimer
{
    if (self.refreshFlowConnectionTimer != nil && self.refreshTimerThread != nil) {
        [self performSelector:@selector(invalidateRefreshTimer) onThread:self.refreshTimerThread withObject:nil waitUntilDone:YES];
        [self cleanupRefreshTimer];
    }
}

- (void)invalidateRefreshTimer
{
    [self.refreshFlowConnectionTimer invalidate];
}

- (void)cleanupRefreshTimer
{
    self.refreshFlowConnectionTimer = nil;
    self.refreshTimerThread = nil;
}

- (void)refreshFlowConnectionTimerFired:(NSTimer *)rfcTimer
{
    // If this timer fired, the timeout period for the refresh flow has expired, without the
    // refresh flow completing.
    
    [self cleanupRefreshTimer];
    [self log:SFLogLevelDebug format:@"Refresh attempt timed out after %f seconds.", self.timeout];
    [self stopAuthentication];
    NSError *error = [[self class] errorWithType:kSFOAuthErrorTypeTimeout
                                     description:@"The token refresh process timed out."];
    [self notifyDelegateOfFailure:error authInfo:self.authInfo];
}

+ (NSString *)advancedAuthStateDesc:(SFOAuthAdvancedAuthState)authState
{
    switch (authState) {
        case SFOAuthAdvancedAuthStateBrowserRequestInitiated:
            return @"SFOAuthAdvancedAuthStateBrowserRequestInitiated";
            break;
        case SFOAuthAdvancedAuthStateNotStarted:
            return @"SFOAuthAdvancedAuthStateNotStarted";
            break;
        case SFOAuthAdvancedAuthStateTokenRequestInitiated:
            return @"SFOAuthAdvancedAuthStateTokenRequestInitiated";
        default:
            return [NSString stringWithFormat:@"Unknown auth state (%lu)", (unsigned long)authState];
    }
}

#pragma mark - UIWebViewDelegate (User-Agent Token Flow)

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType {
    
    if (self.credentials.logLevel < kSFOAuthLogLevelWarning) {
        [self log:SFLogLevelDebug format:@"%@ (navType=%ld): host=%@ : path=%@",
         NSStringFromSelector(_cmd), (long)navigationType, request.URL.host, request.URL.path];
    }
    
    BOOL result = YES;
    NSURL *requestUrl = [request URL];
    NSString *requestUrlString = [requestUrl absoluteString];
    if ([[requestUrlString lowercaseString] hasPrefix:[self.credentials.redirectUri lowercaseString]]) {
        result = NO; // we're finished, don't load this request
        [self handleUserAgentResponse:requestUrl];
    }
    
    return result;
}

- (void)webViewDidStartLoad:(UIWebView *)webView {
    NSURL *url = webView.request.URL;
    
    if (self.credentials.logLevel < kSFOAuthLogLevelWarning) {
        [self log:SFLogLevelDebug format:@"%@ host=%@ : path=%@", NSStringFromSelector(_cmd), url.host, url.path];
    }
    
    if ([self.delegate respondsToSelector:@selector(oauthCoordinator:didStartLoad:)]) {
        [self.delegate oauthCoordinator:self didStartLoad:webView];
    }
}

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    if ([self.delegate respondsToSelector:@selector(oauthCoordinator:didFinishLoad:error:)]) {
        [self.delegate oauthCoordinator:self didFinishLoad:webView error:nil];
    }
    if (!self.initialRequestLoaded) {
        self.initialRequestLoaded = YES;
        [self.delegate oauthCoordinator:self didBeginAuthenticationWithView:self.view];
        NSAssert((nil != [self.view superview]), @"No superview for oauth web view after didBeginAuthenticationWithView");
    }
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    
    // Report all errors other than -999 (operation couldn't be completed), which is not catastrophic.
    // Typical errors encountered (many others are possible):
    // WebKitErrorDomain:
    //      -999 The operation couldn't be completed.
    // NSURLErrorDomain:
    //      -999 The operation couldn't be completed.
    //     -1001 The request timed out.
    
    if ([self.delegate respondsToSelector:@selector(oauthCoordinator:didFinishLoad:error:)]) {
        [self.delegate oauthCoordinator:self didFinishLoad:webView error:error];
    }
    
    NSURL *requestUrl = [webView.request URL];
    NSString *errorUrlString = [NSString stringWithFormat:@"%@://%@%@", [requestUrl scheme], [requestUrl host], [requestUrl relativePath]];
    if (-999 == error.code) {
        // -999 errors (operation couldn't be completed) occur during normal execution, therefore only log for debugging
        if (self.credentials.logLevel < kSFOAuthLogLevelInfo) {
            [self log:SFLogLevelDebug format:@"SFOAuthCoordinator:didFailLoadWithError: error code: %ld, description: %@, URL: %@", (long)error.code, [error localizedDescription], errorUrlString];
        }
    } else {
        [self log:SFLogLevelDebug format:@"SFOAuthCoordinator:didFailLoadWithError: error code: %ld, description: %@, URL: %@", (long)error.code, [error localizedDescription], errorUrlString];
        [self notifyDelegateOfFailure:error authInfo:self.authInfo];
    }
}

#pragma mark - NSURLConnectionDelegate (Refresh Token Flow)

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    NSURL *requestUrl = [[connection currentRequest] URL];
    NSString *errorUrlString = [NSString stringWithFormat:@"%@://%@%@", [requestUrl scheme], [requestUrl host], [requestUrl relativePath]];
	[self log:SFLogLevelDebug format:@"SFOAuthCoordinator:connection:didFailWithError: error code: %ld, description: %@, URL: %@", (long)error.code, [error localizedDescription], errorUrlString];
    [self stopRefreshFlowConnectionTimer];
    [self notifyDelegateOfFailure:error authInfo:self.authInfo];
}

- (NSURLRequest *)connection:(NSURLConnection *)connection 
             willSendRequest:(NSURLRequest *)request 
            redirectResponse:(NSURLResponse *)response {
    
	if (nil != response) {
        if (![[request HTTPMethod] isEqualToString:kHttpMethodPost]) {
            // convert the request to a post method if necessary
            NSMutableURLRequest *newRequest = [request mutableCopy];
            [newRequest setHTTPMethod:kHttpMethodPost];
            request = newRequest;
        }
	}
	return request;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	// reset the response data for a new refresh response
    self.responseData = [NSMutableData dataWithCapacity:kSFOAuthReponseBufferLength];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	[self.responseData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	[self.oauthCoordinatorFlow handleTokenEndpointResponse];
}

#pragma mark - Utilities

+ (NSDictionary *)parseQueryString:(NSString *)query {
    return [self parseQueryString:query decodeParams:YES];
}

+ (NSDictionary *)parseQueryString:(NSString *)query decodeParams:(BOOL)decodeParams {
    NSArray *pairs = [query componentsSeparatedByString:@"&"]; // TODO: support semicolon delimiter also
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] initWithCapacity:pairs.count];
    for (NSString *pair in pairs) {
        NSArray *keyValue = [pair componentsSeparatedByString:@"="];
        NSString *key = keyValue[0];
        NSString *value = keyValue[1];
        if (decodeParams) {
            key = [[key
                    stringByReplacingOccurrencesOfString:@"+" withString:@" "]
                   stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            value = [[value
                      stringByReplacingOccurrencesOfString:@"+" withString:@" "]
                     stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        }
        dict[key] = value;
    }
    NSDictionary *result = [NSDictionary dictionaryWithDictionary:dict];
    return result;
}

+ (NSError *)errorWithType:(NSString *)type description:(NSString *)description {
    NSAssert(type, @"error type can't be nil");
    
    NSInteger code = kSFOAuthErrorUnknown;
    if ([type isEqualToString:kSFOAuthErrorTypeAccessDenied]) {
        code = kSFOAuthErrorAccessDenied;
    } else if ([type isEqualToString:kSFOAuthErrorTypeMalformedResponse]) {
        code = kSFOAuthErrorMalformed;
    } else if ([type isEqualToString:KSFOAuthErrorTypeInvalidClientId]) {
        code = kSFOAuthErrorInvalidClientId;
    } else if ([type isEqualToString:kSFOAuthErrorTypeInvalidClient]) {
        code = kSFOAuthErrorInvalidClientCredentials;
    } else if ([type isEqualToString:kSFOAuthErrorTypeInvalidClientCredentials]) {
        code = kSFOAuthErrorInvalidClientCredentials;
    } else if ([type isEqualToString:kSFOAuthErrorTypeInvalidGrant]) {
        code = kSFOAuthErrorInvalidGrant;
    } else if ([type isEqualToString:kSFOAuthErrorTypeInvalidRequest]) {
        code = kSFOAuthErrorInvalidRequest;
    } else if ([type isEqualToString:kSFOAuthErrorTypeInactiveUser]) {
        code = kSFOAuthErrorInactiveUser;
    }  else if ([type isEqualToString:kSFOAuthErrorTypeInactiveOrg]) {
        code = kSFOAuthErrorInactiveOrg;
    }  else if ([type isEqualToString:kSFOAuthErrorTypeRateLimitExceeded]) {
        code = kSFOAuthErrorRateLimitExceeded;
    }  else if ([type isEqualToString:kSFOAuthErrorTypeUnsupportedResponseType]) {
        code = kSFOAuthErrorUnsupportedResponseType;
    } else if ([type isEqualToString:kSFOAuthErrorTypeTimeout]) {
        code = kSFOAuthErrorTimeout;
    } else if ([type isEqualToString:kSFOAuthErrorTypeWrongVersion]) {
        code = kSFOAuthErrorWrongVersion;
    } else if ([type isEqualToString:kSFOAuthErrorTypeBrowserLaunchFailed]) {
        code = kSFOAuthErrorBrowserLaunchFailed;
    } else if ([type isEqualToString:kSFOAuthErrorTypeUnknownAdvancedAuthConfig]) {
        code = kSFOAuthErrorUnknownAdvancedAuthConfig;
    }

    NSDictionary *dict = @{kSFOAuthError: type,
                                                                    NSLocalizedDescriptionKey: description};
    NSError *error = [NSError errorWithDomain:kSFOAuthErrorDomain code:code userInfo:dict];
    return error;
}

// Convert from a Unix timestamp string in milliseconds (returned in the OAuth response) to an NSDate
+ (NSDate *)timestampStringToDate:(NSString *)timestamp {
    NSDate *d = nil;
    if (timestamp != nil) {
        NSTimeInterval unixTimeInSecs = [timestamp longLongValue] / 1000; // convert from millis to secs
        d = [NSDate dateWithTimeIntervalSince1970:unixTimeInSecs];
    }
    return d;
}

@end
