using System.Security.Cryptography;
using System.Text;

namespace Swapdeck;

// Velopack Setup ends with the full package. Our footer locates its signed feed
// without executing the downloaded setup program. All lengths are little endian.
public static class BundledUpdate
{
    public static void Extract(string setup, string directory, Version version)
    {
        using var input = File.OpenRead(setup);
        using var reader = new BinaryReader(input, Encoding.UTF8, true);
        const int footerSize = 16;
        if (input.Length < footerSize) throw new InvalidDataException("更新包不完整。");
        input.Position = input.Length - footerSize;
        int manifestLength = reader.ReadInt32(), signatureLength = reader.ReadInt32();
        if (!reader.ReadBytes(8).AsSpan().SequenceEqual("SWPDK001"u8) ||
            manifestLength is <= 0 or > 1048576 || signatureLength is <= 0 or > 1024)
            throw new InvalidDataException("无法识别安装包内的更新信息。");
        long manifestStart = input.Length - footerSize - manifestLength - signatureLength;
        if (manifestStart <= 0) throw new InvalidDataException("更新信息不完整。");
        input.Position = manifestStart;
        var manifest = reader.ReadBytes(manifestLength);
        Updates.Verify(manifest, reader.ReadBytes(signatureLength));
        var assets = JsonNode.Parse(manifest)?["Assets"]?.AsArray();
        var item = assets?.Count == 1 ? assets[0] : null;
        string name = $"Swapdeck.Windows-{version}-win-x64-full.nupkg";
        long size = (long?)item?["Size"] ?? 0;
        if (item?["PackageId"]?.ToString() != "Swapdeck.Windows" || item["Version"]?.ToString() != version.ToString() ||
            item["Type"]?.ToString() != "Full" || item["FileName"]?.ToString() != name || size <= 0 || size >= manifestStart)
            throw new InvalidDataException("签名更新清单与所选版本不匹配。");
        input.Position = manifestStart - size;
        Directory.CreateDirectory(directory);
        using (var package = File.Create(Path.Combine(directory, name)))
        using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
        {
            var buffer = new byte[81920];
            for (long left = size; left > 0;)
            {
                int count = (int)Math.Min(left, buffer.Length);
                input.ReadExactly(buffer.AsSpan(0, count));
                package.Write(buffer, 0, count);
                hash.AppendData(buffer, 0, count);
                left -= count;
            }
            if (!Convert.ToHexString(hash.GetHashAndReset()).Equals(item["SHA256"]?.ToString(), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("安装包内的更新数据校验失败。");
        }
        File.WriteAllBytes(Path.Combine(directory, "releases.win-x64.json"), manifest);
    }
}
