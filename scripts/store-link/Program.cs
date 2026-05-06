using StoreLib.Models;
using StoreLib.Services;

if (args.Length < 1)
{
    Console.Error.WriteLine("Usage: StoreLink <product-id> [architecture]");
    return 2;
}

var productId = args[0];
var architecture = args.Length > 1 ? args[1] : "x64";

var dcat = DisplayCatalogHandler.ProductionConfig();
await dcat.QueryDCATAsync(productId, IdentiferType.ProductID);

if (dcat.Error is not null)
{
    Console.Error.WriteLine(dcat.Error);
}

var packages = await dcat.GetPackagesForProductAsync();
var package = packages
    .Where(p => p.PackageUri is not null)
    .Where(p => p.PackageMoniker.Contains($@"_{architecture}__", StringComparison.OrdinalIgnoreCase))
    .Where(p => p.PackageMoniker.StartsWith("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase))
    .OrderByDescending(p => ExtractVersion(p.PackageMoniker))
    .FirstOrDefault();

if (package is null)
{
    Console.Error.WriteLine($"No matching package found for {productId} / {architecture}.");
    foreach (var candidate in packages)
    {
        Console.Error.WriteLine($"{candidate.PackageType}\t{candidate.PackageMoniker}\t{candidate.PackageUri}");
    }
    return 1;
}

Console.WriteLine($"{package.PackageMoniker}\t{package.PackageUri}");
return 0;

static Version ExtractVersion(string packageMoniker)
{
    var parts = packageMoniker.Split('_');
    if (parts.Length > 1 && Version.TryParse(parts[1], out var version))
    {
        return version;
    }

    return new Version(0, 0, 0, 0);
}
