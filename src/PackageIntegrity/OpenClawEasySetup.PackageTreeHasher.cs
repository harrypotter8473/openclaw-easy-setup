using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace OpenClawEasySetup.Integrity
{
    public sealed class PackageTreeDigestResult
    {
        public string Sha256 { get; set; }
        public string MetadataSha256 { get; set; }
        public int FileCount { get; set; }
        public long TotalBytes { get; set; }
    }

    public sealed class PackageTreeMetadataDigestResult
    {
        public string Sha256 { get; set; }
        public int FileCount { get; set; }
        public long TotalBytes { get; set; }
    }

    public static class PackageTreeHasher
    {
        private const int MaximumEntries = 100000;
        private const int MaximumFiles = 50000;
        private const long MaximumBytes = 2147483648L;

        public static PackageTreeDigestResult Compute(string packageRoot)
        {
            TreeSnapshot snapshot = Capture(packageRoot);
            StringBuilder contentManifest = new StringBuilder();

            using (SHA256 sha256 = SHA256.Create())
            {
                foreach (FileSnapshot file in snapshot.Files)
                {
                    ValidateUnchangedFile(file);

                    byte[] hash;
                    using (FileStream stream = new FileStream(
                        file.FullPath,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.Read,
                        65536,
                        FileOptions.SequentialScan))
                    {
                        if (stream.Length != file.Length)
                        {
                            throw new InvalidOperationException("An OpenClaw package file changed during integrity verification.");
                        }

                        sha256.Initialize();
                        hash = sha256.ComputeHash(stream);
                    }

                    ValidateUnchangedFile(file);
                    contentManifest.Append(file.RelativePath)
                        .Append('\0')
                        .Append(file.Length.ToString(CultureInfo.InvariantCulture))
                        .Append('\0')
                        .Append(ToHex(hash))
                        .Append('\n');
                }

                // A second metadata pass catches ordinary additions, removals, renames, and
                // timestamp/attribute changes that race the slower content-hash pass.
                TreeSnapshot finalSnapshot = Capture(packageRoot);
                if (!String.Equals(snapshot.MetadataSha256, finalSnapshot.MetadataSha256, StringComparison.Ordinal) ||
                    snapshot.FileCount != finalSnapshot.FileCount ||
                    snapshot.TotalBytes != finalSnapshot.TotalBytes)
                {
                    throw new InvalidOperationException("The OpenClaw package tree changed during integrity verification.");
                }

                byte[] manifestBytes = new UTF8Encoding(false).GetBytes(contentManifest.ToString());
                sha256.Initialize();
                return new PackageTreeDigestResult
                {
                    Sha256 = ToHex(sha256.ComputeHash(manifestBytes)),
                    MetadataSha256 = finalSnapshot.MetadataSha256,
                    FileCount = finalSnapshot.FileCount,
                    TotalBytes = finalSnapshot.TotalBytes
                };
            }
        }

        public static PackageTreeMetadataDigestResult ComputeMetadata(string packageRoot)
        {
            TreeSnapshot snapshot = Capture(packageRoot);
            return new PackageTreeMetadataDigestResult
            {
                Sha256 = snapshot.MetadataSha256,
                FileCount = snapshot.FileCount,
                TotalBytes = snapshot.TotalBytes
            };
        }

        public static string ComputeFile(string path, long maximumBytes)
        {
            if (maximumBytes <= 0)
            {
                throw new ArgumentOutOfRangeException("maximumBytes");
            }

            string fullPath = Path.GetFullPath(path);
            FileSnapshot before = CaptureSingleFile(fullPath, maximumBytes);
            byte[] hash;
            using (SHA256 sha256 = SHA256.Create())
            using (FileStream stream = new FileStream(
                fullPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                65536,
                FileOptions.SequentialScan))
            {
                if (stream.Length != before.Length)
                {
                    throw new InvalidOperationException("An OpenClaw critical file changed during integrity verification.");
                }
                hash = sha256.ComputeHash(stream);
            }

            FileSnapshot after = CaptureSingleFile(fullPath, maximumBytes);
            if (!HasSameMetadata(before, after))
            {
                throw new InvalidOperationException("An OpenClaw critical file changed during integrity verification.");
            }
            return ToHex(hash);
        }

        private static TreeSnapshot Capture(string packageRoot)
        {
            string root = Path.GetFullPath(packageRoot);
            FileAttributes rootAttributes = File.GetAttributes(root);
            if ((rootAttributes & FileAttributes.Directory) == 0 ||
                (rootAttributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidOperationException("The OpenClaw package root was not a normal directory.");
            }

            string rootPrefix = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            Stack<string> directories = new Stack<string>();
            List<FileSnapshot> files = new List<FileSnapshot>();
            directories.Push(root);
            int entryCount = 0;
            long totalBytes = 0;

            while (directories.Count > 0)
            {
                string directory = directories.Pop();
                DirectoryInfo directoryInfo = new DirectoryInfo(directory);
                directoryInfo.Refresh();
                if ((directoryInfo.Attributes & FileAttributes.Directory) == 0 ||
                    (directoryInfo.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new InvalidOperationException("An OpenClaw package directory changed type during integrity verification.");
                }

                foreach (FileSystemInfo entry in directoryInfo.EnumerateFileSystemInfos())
                {
                    entryCount++;
                    if (entryCount > MaximumEntries)
                    {
                        throw new InvalidOperationException("The OpenClaw package tree contained too many filesystem entries.");
                    }

                    string fullPath = Path.GetFullPath(entry.FullName);
                    if (!fullPath.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidOperationException("An OpenClaw package entry left the package root.");
                    }

                    FileAttributes attributes = entry.Attributes;
                    if ((attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        throw new InvalidOperationException("The OpenClaw package tree contained a reparse point.");
                    }

                    if ((attributes & FileAttributes.Directory) != 0)
                    {
                        directories.Push(fullPath);
                        continue;
                    }

                    FileInfo info = entry as FileInfo;
                    if (info == null)
                    {
                        info = new FileInfo(fullPath);
                        info.Refresh();
                    }
                    if ((info.Attributes & FileAttributes.Directory) != 0 ||
                        (info.Attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        throw new InvalidOperationException("An OpenClaw package file changed type during integrity verification.");
                    }
                    long length = info.Length;
                    totalBytes += length;
                    if (totalBytes > MaximumBytes)
                    {
                        throw new InvalidOperationException("The OpenClaw package tree exceeded the integrity size limit.");
                    }

                    files.Add(new FileSnapshot
                    {
                        FullPath = fullPath,
                        RelativePath = fullPath.Substring(rootPrefix.Length).Replace('\\', '/'),
                        Length = length,
                        CreationTimeUtcTicks = info.CreationTimeUtc.Ticks,
                        LastWriteTimeUtcTicks = info.LastWriteTimeUtc.Ticks,
                        Attributes = info.Attributes
                    });
                    if (files.Count > MaximumFiles)
                    {
                        throw new InvalidOperationException("The OpenClaw package tree contained an unexpected number of files.");
                    }
                }
            }

            if (files.Count == 0)
            {
                throw new InvalidOperationException("The OpenClaw package tree contained an unexpected number of files.");
            }

            files.Sort(FileSnapshotComparer.Instance);
            StringBuilder metadataManifest = new StringBuilder();
            foreach (FileSnapshot file in files)
            {
                metadataManifest.Append(file.RelativePath)
                    .Append('\0')
                    .Append(file.Length.ToString(CultureInfo.InvariantCulture))
                    .Append('\0')
                    .Append(file.CreationTimeUtcTicks.ToString(CultureInfo.InvariantCulture))
                    .Append('\0')
                    .Append(file.LastWriteTimeUtcTicks.ToString(CultureInfo.InvariantCulture))
                    .Append('\0')
                    .Append(((int)file.Attributes).ToString(CultureInfo.InvariantCulture))
                    .Append('\n');
            }

            using (SHA256 sha256 = SHA256.Create())
            {
                byte[] manifestBytes = new UTF8Encoding(false).GetBytes(metadataManifest.ToString());
                return new TreeSnapshot
                {
                    Files = files,
                    MetadataSha256 = ToHex(sha256.ComputeHash(manifestBytes)),
                    FileCount = files.Count,
                    TotalBytes = totalBytes
                };
            }
        }

        private static void ValidateUnchangedFile(FileSnapshot expected)
        {
            FileInfo current = new FileInfo(expected.FullPath);
            current.Refresh();
            FileSnapshot actual = new FileSnapshot
            {
                FullPath = expected.FullPath,
                Length = current.Length,
                CreationTimeUtcTicks = current.CreationTimeUtc.Ticks,
                LastWriteTimeUtcTicks = current.LastWriteTimeUtc.Ticks,
                Attributes = current.Attributes
            };
            if ((actual.Attributes & FileAttributes.Directory) != 0 ||
                (actual.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidOperationException("An OpenClaw package file changed type during integrity verification.");
            }
            if (!HasSameMetadata(expected, actual))
            {
                throw new InvalidOperationException("An OpenClaw package file changed during integrity verification.");
            }
        }

        private static FileSnapshot CaptureSingleFile(string fullPath, long maximumBytes)
        {
            FileInfo info = new FileInfo(fullPath);
            info.Refresh();
            if ((info.Attributes & FileAttributes.Directory) != 0 ||
                (info.Attributes & FileAttributes.ReparsePoint) != 0 ||
                info.Length <= 0 ||
                info.Length > maximumBytes)
            {
                throw new InvalidOperationException("The OpenClaw critical file was unsafe.");
            }
            return new FileSnapshot
            {
                FullPath = fullPath,
                Length = info.Length,
                CreationTimeUtcTicks = info.CreationTimeUtc.Ticks,
                LastWriteTimeUtcTicks = info.LastWriteTimeUtc.Ticks,
                Attributes = info.Attributes
            };
        }

        private static bool HasSameMetadata(FileSnapshot left, FileSnapshot right)
        {
            return left.Length == right.Length &&
                left.CreationTimeUtcTicks == right.CreationTimeUtcTicks &&
                left.LastWriteTimeUtcTicks == right.LastWriteTimeUtcTicks &&
                left.Attributes == right.Attributes;
        }

        private static string ToHex(byte[] value)
        {
            StringBuilder result = new StringBuilder(value.Length * 2);
            for (int index = 0; index < value.Length; index++)
            {
                result.Append(value[index].ToString("X2", CultureInfo.InvariantCulture));
            }
            return result.ToString();
        }

        private sealed class FileSnapshot
        {
            public string FullPath { get; set; }
            public string RelativePath { get; set; }
            public long Length { get; set; }
            public long CreationTimeUtcTicks { get; set; }
            public long LastWriteTimeUtcTicks { get; set; }
            public FileAttributes Attributes { get; set; }
        }

        private sealed class TreeSnapshot
        {
            public List<FileSnapshot> Files { get; set; }
            public string MetadataSha256 { get; set; }
            public int FileCount { get; set; }
            public long TotalBytes { get; set; }
        }

        private sealed class FileSnapshotComparer : IComparer<FileSnapshot>
        {
            public static readonly FileSnapshotComparer Instance = new FileSnapshotComparer();

            public int Compare(FileSnapshot left, FileSnapshot right)
            {
                int comparison = StringComparer.OrdinalIgnoreCase.Compare(left.RelativePath, right.RelativePath);
                if (comparison != 0)
                {
                    return comparison;
                }
                return StringComparer.Ordinal.Compare(left.RelativePath, right.RelativePath);
            }
        }
    }
}
