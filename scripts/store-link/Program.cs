using System.Globalization;
using System.Net;
using System.Net.Security;
using System.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;

internal static class Program
{
    private const string DefaultPackageIdentity = "OpenAI.Codex";
    private const string DisplayCatalogBaseUrl = "https://displaycatalog.mp.microsoft.com/v7.0/products";
    private const string Fe3Host = "fe3.delivery.mp.microsoft.com";
    private const string Fe3Endpoint = "https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx";
    private const string Fe3SecuredEndpoint = "https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx/secured";
    // X509Certificate2.Thumbprint is SHA-1. This pins the Microsoft Update
    // Secure Server CA 2.1 intermediate that signs FE3 delivery certificates.
    private const string MicrosoftUpdateSecureServerCa21Sha1Thumbprint =
        "7EED6032C9F56387EC734CBBF32BFC14DB6DE0A2";

    // Baseline non-leaf Windows Store categories/detectoids needed for FE3 to
    // evaluate a normal Windows Desktop x64 device and return package updates.
    private static readonly int[] WindowsDesktopBaselineInstalledUpdateIds =
    {
        1,
        2,
        3,
        11,
        19,
        544,
        549,
        2359974,
        5169044,
        8788830,
        23110993,
        23110994,
        54341900,
        54343656,
        59830006,
        59830007,
        59830008,
        60484010,
        62450018,
        62450019,
        62450020,
        66027979,
        66053150,
        97657898,
        98822896,
        98959022,
        98959023,
        98959024,
        98959025,
        98959026,
        104433538,
        104900364,
        105489019,
        117765322,
        129905029,
        130040031,
        132387090,
        132393049,
        // Required for FE3 to consider Windows Desktop ARM64 Store packages applicable.
        133399034,
        138537048,
        140377312,
        143747671,
        158941041,
        158941042,
        158941043,
        158941044,
        159123858,
        159130928,
        164836897,
        164847386,
        164848327,
        164852241,
        164852246,
        164852252,
        164852253,
    };

    public static async Task<int> Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: StoreLink <product-id> [architecture] [package-identity]");
            return 2;
        }

        var productId = args[0];
        var architecture = NormalizeArchitecture(args.Length > 1 ? args[1] : "x64");
        var packageIdentity = args.Length > 2 ? args[2].Trim() : DefaultPackageIdentity;
        if (string.IsNullOrWhiteSpace(packageIdentity) || packageIdentity.Contains('_'))
        {
            Console.Error.WriteLine($"Invalid package identity: '{packageIdentity}'.");
            return 2;
        }

        using var handler = new HttpClientHandler
        {
            ServerCertificateCustomValidationCallback = ValidateServerCertificate,
        };
        using var httpClient = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(120),
        };
        httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("codex-app-mirror/1.0");
        httpClient.DefaultRequestHeaders.TryAddWithoutValidation("MS-CV", Guid.NewGuid().ToString("N")[..16] + ".0");

        try
        {
            var wuCategoryId = await ResolveWuCategoryIdAsync(httpClient, productId);
            var cookie = await GetCookieAsync(httpClient);
            var deviceAttributes = WindowsDesktopDeviceAttributesFor(architecture);
            var syncXml = await SyncUpdatesAsync(httpClient, cookie, wuCategoryId, deviceAttributes);
            var candidates = ParsePackageCandidates(syncXml);
            var package = candidates
                .Where(p => MatchesPackageIdentity(p.PackageMoniker, packageIdentity))
                .Where(p => p.PackageMoniker.Contains($"_{architecture}__", StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(p => ExtractVersion(p.PackageMoniker))
                .FirstOrDefault();

            if (package is null)
            {
                Console.Error.WriteLine($"No matching package found for {productId} / {packageIdentity} / {architecture}.");
                foreach (var candidate in candidates.OrderBy(c => c.PackageMoniker, StringComparer.OrdinalIgnoreCase))
                {
                    Console.Error.WriteLine($"{candidate.PackageType}\t{candidate.PackageMoniker}\t{candidate.UpdateId}/{candidate.RevisionNumber}");
                }

                return 1;
            }

            var packageUrl = await GetPackageUrlAsync(
                httpClient,
                package.UpdateId,
                package.RevisionNumber,
                deviceAttributes);
            Console.WriteLine($"{package.PackageMoniker}\t{packageUrl}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
    }

    private static async Task<string> ResolveWuCategoryIdAsync(HttpClient httpClient, string productId)
    {
        var url = $"{DisplayCatalogBaseUrl}/{Uri.EscapeDataString(productId)}?market=US&languages=en-US,en,neutral";
        using var response = await httpClient.GetAsync(url);
        var content = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, content);

        using var document = JsonDocument.Parse(content);
        var wuCategoryId = FindStringProperty(document.RootElement, "WuCategoryId");
        if (string.IsNullOrWhiteSpace(wuCategoryId))
        {
            throw new InvalidOperationException($"DisplayCatalog did not return a WuCategoryId for {productId}.");
        }

        return wuCategoryId;
    }

    private static bool ValidateServerCertificate(
        HttpRequestMessage request,
        X509Certificate2? certificate,
        X509Chain? chain,
        SslPolicyErrors sslPolicyErrors)
    {
        if (sslPolicyErrors == SslPolicyErrors.None)
        {
            return true;
        }

        if (sslPolicyErrors != SslPolicyErrors.RemoteCertificateChainErrors
            || certificate is null
            || chain is null
            || !string.Equals(request.RequestUri?.Host, Fe3Host, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var now = DateTime.UtcNow;
        if (now < certificate.NotBefore.ToUniversalTime() || now > certificate.NotAfter.ToUniversalTime())
        {
            return false;
        }

        var hasOnlyExpectedChainErrors = chain.ChainStatus.Length > 0
            && chain.ChainStatus.All(status =>
                status.Status is X509ChainStatusFlags.UntrustedRoot or X509ChainStatusFlags.PartialChain);
        var hasExpectedDeliveryName = certificate.GetNameInfo(X509NameType.DnsName, false)
            .Equals("*.delivery.mp.microsoft.com", StringComparison.OrdinalIgnoreCase);
        if (!hasOnlyExpectedChainErrors || !hasExpectedDeliveryName || chain.ChainElements.Count < 2)
        {
            return false;
        }

        var intermediate = chain.ChainElements[1].Certificate;
        var hasPinnedIntermediate = string.Equals(
            NormalizeThumbprint(intermediate.Thumbprint),
            MicrosoftUpdateSecureServerCa21Sha1Thumbprint,
            StringComparison.OrdinalIgnoreCase);
        var chainsToPinnedIntermediate = string.Equals(certificate.Issuer, intermediate.Subject, StringComparison.Ordinal);

        return hasPinnedIntermediate && chainsToPinnedIntermediate;
    }

    private static async Task<string> GetCookieAsync(HttpClient httpClient)
    {
        var now = DateTimeOffset.UtcNow;
        var body = $"""
            <GetCookie xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
              <oldCookie></oldCookie>
              <lastChange>2015-10-21T17:01:07.1472913Z</lastChange>
              <currentTime>{FormatSoapDate(now)}</currentTime>
              <protocolVersion>1.40</protocolVersion>
            </GetCookie>
            """;
        var soap = BuildSoapEnvelope(
            "http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie",
            Fe3Endpoint,
            body);

        var content = await PostSoapAsync(httpClient, Fe3Endpoint, soap);
        var document = XDocument.Parse(content);
        var encryptedData = document
            .Descendants()
            .FirstOrDefault(e => e.Name.LocalName == "EncryptedData")
            ?.Value;

        if (string.IsNullOrWhiteSpace(encryptedData))
        {
            throw new InvalidOperationException("FE3 GetCookie did not return EncryptedData.");
        }

        return encryptedData;
    }

    private static async Task<string> SyncUpdatesAsync(
        HttpClient httpClient,
        string cookie,
        string wuCategoryId,
        string deviceAttributes)
    {
        var installedIds = string.Join("", WindowsDesktopBaselineInstalledUpdateIds.Select(id => $"<int>{id}</int>"));
        var body = $"""
            <SyncUpdates xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
              <cookie>
                <Expiration>{FormatSoapDate(DateTimeOffset.UtcNow.AddDays(1))}</Expiration>
                <EncryptedData>{XmlEscape(cookie)}</EncryptedData>
              </cookie>
              <parameters>
                <ExpressQuery>false</ExpressQuery>
                <InstalledNonLeafUpdateIDs>{installedIds}</InstalledNonLeafUpdateIDs>
                <OtherCachedUpdateIDs></OtherCachedUpdateIDs>
                <SkipSoftwareSync>false</SkipSoftwareSync>
                <NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>
                <FilterAppCategoryIds>
                  <CategoryIdentifier>
                    <Id>{XmlEscape(wuCategoryId)}</Id>
                  </CategoryIdentifier>
                </FilterAppCategoryIds>
                <TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
                <AlsoPerformRegularSync>false</AlsoPerformRegularSync>
                <ComputerSpec />
                <ExtendedUpdateInfoParameters>
                  <XmlUpdateFragmentTypes>
                    <XmlUpdateFragmentType>Extended</XmlUpdateFragmentType>
                  </XmlUpdateFragmentTypes>
                  <Locales>
                    <string>en-US</string>
                    <string>en</string>
                  </Locales>
                </ExtendedUpdateInfoParameters>
                <ClientPreferredLanguages>
                  <string>en-US</string>
                </ClientPreferredLanguages>
                <ProductsParameters>
                  <SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>
                  <DeviceAttributes>{XmlEscape(deviceAttributes)}</DeviceAttributes>
                  <CallerAttributes>Interactive=1;IsSeeker=0;</CallerAttributes>
                  <Products />
                </ProductsParameters>
              </parameters>
            </SyncUpdates>
            """;
        var soap = BuildSoapEnvelope(
            "http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/SyncUpdates",
            Fe3Endpoint,
            body);

        return await PostSoapAsync(httpClient, Fe3Endpoint, soap);
    }

    private static IReadOnlyList<PackageCandidate> ParsePackageCandidates(string syncUpdatesXml)
    {
        var document = XDocument.Parse(syncUpdatesXml);
        var candidates = new List<PackageCandidate>();

        foreach (var xmlElement in document.Descendants().Where(e => e.Name.LocalName == "Xml"))
        {
            var fragment = xmlElement.Value;
            var fragmentDocument = TryParseXmlFragment(fragment);
            if (!HasPackageFragmentElements(fragmentDocument))
            {
                var decodedFragment = WebUtility.HtmlDecode(fragment);
                if (!string.Equals(decodedFragment, fragment, StringComparison.Ordinal))
                {
                    var decodedDocument = TryParseXmlFragment(decodedFragment);
                    if (HasPackageFragmentElements(decodedDocument))
                    {
                        fragmentDocument = decodedDocument;
                    }
                }

            }
            if (fragmentDocument is null || !HasPackageFragmentElements(fragmentDocument))
            {
                continue;
            }

            var identityElement = fragmentDocument
                .Descendants()
                .FirstOrDefault(e => e.Name.LocalName == "UpdateIdentity");
            var packageElement = fragmentDocument
                .Descendants()
                .FirstOrDefault(e => e.Name.LocalName == "AppxMetadata");
            var updateId = AttributeOrElement(identityElement, "UpdateID");
            var revisionNumber = AttributeOrElement(identityElement, "RevisionNumber");
            var packageMoniker = AttributeOrElement(packageElement, "PackageMoniker");
            var packageType = AttributeOrElement(packageElement, "PackageType");

            if (string.IsNullOrWhiteSpace(updateId)
                || string.IsNullOrWhiteSpace(revisionNumber)
                || string.IsNullOrWhiteSpace(packageMoniker)
                || string.IsNullOrWhiteSpace(packageType))
            {
                continue;
            }

            candidates.Add(new PackageCandidate(
                packageMoniker,
                packageType,
                updateId,
                revisionNumber));
        }

        return candidates;
    }

    private static async Task<string> GetPackageUrlAsync(
        HttpClient httpClient,
        string updateId,
        string revisionNumber,
        string deviceAttributes)
    {
        var body = $"""
            <GetExtendedUpdateInfo2 xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
              <updateIDs>
                <UpdateIdentity>
                  <UpdateID>{XmlEscape(updateId)}</UpdateID>
                  <RevisionNumber>{XmlEscape(revisionNumber)}</RevisionNumber>
                </UpdateIdentity>
              </updateIDs>
              <infoTypes>
                <XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType>
                <XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType>
              </infoTypes>
              <deviceAttributes>{XmlEscape(deviceAttributes)}</deviceAttributes>
            </GetExtendedUpdateInfo2>
            """;
        var soap = BuildSoapEnvelope(
            "http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetExtendedUpdateInfo2",
            Fe3SecuredEndpoint,
            body);
        var content = await PostSoapAsync(httpClient, Fe3SecuredEndpoint, soap);
        var document = XDocument.Parse(content);
        var urls = document
            .Descendants()
            .Where(e => e.Name.LocalName == "Url")
            .Select(e => e.Value)
            .Select(url => Uri.TryCreate(url, UriKind.Absolute, out var uri) ? uri : null)
            .Where(uri => uri is not null && IsAllowedPackageUri(uri))
            .OrderByDescending(uri => uri!.AbsoluteUri.Length)
            .Select(uri => uri!.AbsoluteUri)
            .ToList();

        return urls.FirstOrDefault()
            ?? throw new InvalidOperationException($"FE3 did not return a package URL for {updateId}/{revisionNumber}.");
    }

    private static string BuildSoapEnvelope(string action, string to, string body)
    {
        return $"""
            <s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
              <s:Header>
                <a:Action s:mustUnderstand="1">{XmlEscape(action)}</a:Action>
                <a:MessageID>urn:uuid:{Guid.NewGuid()}</a:MessageID>
                <a:To s:mustUnderstand="1">{XmlEscape(to)}</a:To>
                {BuildSecurityHeader()}
              </s:Header>
              <s:Body>
                {body}
              </s:Body>
            </s:Envelope>
            """;
    }

    private static string BuildSecurityHeader()
    {
        var created = DateTimeOffset.UtcNow;
        var expires = created.AddMinutes(5);

        return $"""
            <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
              <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
                <Created>{FormatSoapDate(created)}</Created>
                <Expires>{FormatSoapDate(expires)}</Expires>
              </Timestamp>
              <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
                <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL">
                  <User />
                </TicketType>
              </wuws:WindowsUpdateTicketsToken>
            </o:Security>
            """;
    }

    private static async Task<string> PostSoapAsync(HttpClient httpClient, string url, string soap)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(soap, Encoding.UTF8, "application/soap+xml"),
        };
        using var response = await httpClient.SendAsync(request);
        var content = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, content);
        return content;
    }

    private static void EnsureSuccess(HttpResponseMessage response, string content)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        var snippet = content.Length > 1000 ? content[..1000] : content;
        throw new HttpRequestException($"HTTP {(int)response.StatusCode} {response.ReasonPhrase}: {snippet}");
    }

    private static string? FindStringProperty(JsonElement element, string propertyName)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    if (property.NameEquals(propertyName) && property.Value.ValueKind == JsonValueKind.String)
                    {
                        return property.Value.GetString();
                    }

                    var nested = FindStringProperty(property.Value, propertyName);
                    if (!string.IsNullOrWhiteSpace(nested))
                    {
                        return nested;
                    }
                }

                break;
            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray())
                {
                    var nested = FindStringProperty(item, propertyName);
                    if (!string.IsNullOrWhiteSpace(nested))
                    {
                        return nested;
                    }
                }

                break;
        }

        return null;
    }

    private static bool HasPackageFragmentElements(XDocument? document)
    {
        return document is not null
            && document.Descendants().Any(e => e.Name.LocalName == "AppxMetadata")
            && document.Descendants().Any(e => e.Name.LocalName == "SecuredFragment");
    }

    private static XDocument? TryParseXmlFragment(string fragment)
    {
        try
        {
            return XDocument.Parse($"<Root>{fragment}</Root>");
        }
        catch
        {
            return null;
        }
    }

    private static string AttributeOrElement(XElement? element, string name)
    {
        if (element is null)
        {
            return string.Empty;
        }

        return element.Attribute(name)?.Value
            ?? element.Elements().FirstOrDefault(e => e.Name.LocalName == name)?.Value
            ?? string.Empty;
    }

    private static bool IsAllowedPackageUri(Uri uri)
    {
        if (uri.Scheme is not "http" and not "https")
        {
            return false;
        }

        return HostIsOrSubdomainOf(uri.Host, "dl.delivery.mp.microsoft.com");
    }

    private static bool HostIsOrSubdomainOf(string host, string domain)
    {
        return string.Equals(host, domain, StringComparison.OrdinalIgnoreCase)
            || host.EndsWith($".{domain}", StringComparison.OrdinalIgnoreCase);
    }

    private static string NormalizeThumbprint(string? value)
    {
        return string.Concat((value ?? string.Empty).Where(c => !char.IsWhiteSpace(c) && c != ':'));
    }

    private static Version ExtractVersion(string packageMoniker)
    {
        var parts = packageMoniker.Split('_');
        if (parts.Length > 1 && Version.TryParse(parts[1], out var version))
        {
            return version;
        }

        return new Version(0, 0, 0, 0);
    }

    private static bool MatchesPackageIdentity(string packageMoniker, string expectedIdentity)
    {
        var separator = packageMoniker.IndexOf('_');
        return separator > 0
            && packageMoniker[..separator].Equals(expectedIdentity, StringComparison.OrdinalIgnoreCase);
    }

    private static string NormalizeArchitecture(string architecture)
    {
        return architecture.Trim().ToLowerInvariant() switch
        {
            "amd64" => "x64",
            var value => value,
        };
    }

    private static string WindowsDesktopDeviceAttributesFor(string architecture)
    {
        var osArchitecture = architecture.Equals("arm64", StringComparison.OrdinalIgnoreCase)
            ? "ARM64"
            : "AMD64";
        return $"OSArchitecture={osArchitecture};DeviceFamily=Windows.Desktop;App=WU;AppVer=10.0.22621.1;OSVersion=10.0.22621.1;InstallationType=Client;IsDeviceRetailDemo=0;";
    }

    private static string FormatSoapDate(DateTimeOffset value)
    {
        return value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    }

    private static string XmlEscape(string value)
    {
        return SecurityElement.Escape(value) ?? string.Empty;
    }

    private sealed record PackageCandidate(
        string PackageMoniker,
        string PackageType,
        string UpdateId,
        string RevisionNumber);
}
