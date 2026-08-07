using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace OpenClawEasySetup
{
    internal static class SecretResolverProgram
    {
        private const int ProtocolVersion = 1;
        private const int MaxInputBytes = 65536;
        private const int MaxRequestedIds = 16;
        private const int MaxCredentialBytes = 2560;
        private const int MaxOutputBytes = 262144;
        private const uint CredentialTypeGeneric = 1;
        private const int ErrorNotFound = 1168;
        private const string CredentialTargetPrefix = "OpenClawEasySetup:";

        private static readonly Regex ProviderPattern = new Regex(
            "^[a-z][a-z0-9_-]{0,63}$",
            RegexOptions.CultureInvariant | RegexOptions.Compiled);

        private static readonly Regex CredentialIdPattern = new Regex(
            "^v1/(gateway/auth/token|models/(openai|anthropic|google)/api-key|channels/(slack/(bot-token|app-token)|telegram/bot-token|discord/bot-token))/[A-Fa-f0-9]{32}$",
            RegexOptions.CultureInvariant | RegexOptions.Compiled);

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeCredential
        {
            internal uint Flags;
            internal uint Type;
            internal IntPtr TargetName;
            internal IntPtr Comment;
            internal System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            internal uint CredentialBlobSize;
            internal IntPtr CredentialBlob;
            internal uint Persist;
            internal uint AttributeCount;
            internal IntPtr Attributes;
            internal IntPtr TargetAlias;
            internal IntPtr UserName;
        }

        [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredRead(
            string target,
            uint type,
            int flags,
            out IntPtr credential);

        [DllImport("Advapi32.dll", EntryPoint = "CredFree", SetLastError = false)]
        private static extern void CredFree(IntPtr buffer);

        private static int Main(string[] args)
        {
            if (args == null || args.Length != 0)
            {
                return Fail("invalid request");
            }

            try
            {
                string requestText;
                if (!TryReadBoundedInput(out requestText))
                {
                    return Fail("invalid request");
                }

                string provider;
                IList<string> ids;
                if (!TryParseRequest(requestText, out provider, out ids))
                {
                    return Fail("invalid request");
                }

                // The provider alias is validated as protocol metadata. Credential targets are
                // derived exclusively from validated ids and never from the provider string.
                if (provider.Length == 0)
                {
                    return Fail("invalid request");
                }

                Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.Ordinal);
                Dictionary<string, object> errors = new Dictionary<string, object>(StringComparer.Ordinal);

                foreach (string id in ids)
                {
                    string value;
                    string error;
                    if (TryReadSecret(id, out value, out error))
                    {
                        values.Add(id, value);
                    }
                    else
                    {
                        Dictionary<string, string> errorRecord = new Dictionary<string, string>(StringComparer.Ordinal);
                        errorRecord.Add("message", error);
                        errors.Add(id, errorRecord);
                    }
                }

                Dictionary<string, object> response = new Dictionary<string, object>(StringComparer.Ordinal);
                response.Add("protocolVersion", ProtocolVersion);
                response.Add("values", values);
                if (errors.Count != 0)
                {
                    response.Add("errors", errors);
                }

                if (!TryWriteBoundedResponse(response))
                {
                    return Fail("output limit exceeded");
                }

                return 0;
            }
            catch
            {
                return Fail("resolver failure");
            }
        }

        private static bool TryReadBoundedInput(out string requestText)
        {
            requestText = null;
            byte[] input = new byte[MaxInputBytes + 1];
            int total = 0;
            Stream stream = Console.OpenStandardInput();

            while (total < input.Length)
            {
                int count = stream.Read(input, total, input.Length - total);
                if (count == 0)
                {
                    break;
                }
                total += count;
            }

            if (total == 0 || total > MaxInputBytes)
            {
                Array.Clear(input, 0, input.Length);
                return false;
            }

            try
            {
                UTF8Encoding strictUtf8 = new UTF8Encoding(false, true);
                requestText = strictUtf8.GetString(input, 0, total);
                if (requestText.Length != 0 && requestText[0] == '\ufeff')
                {
                    requestText = requestText.Substring(1);
                }
                return requestText.Length != 0;
            }
            catch (DecoderFallbackException)
            {
                requestText = null;
                return false;
            }
            finally
            {
                Array.Clear(input, 0, input.Length);
            }
        }

        private static bool TryParseRequest(string requestText, out string provider, out IList<string> ids)
        {
            provider = null;
            ids = null;

            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = MaxInputBytes;
            serializer.RecursionLimit = 8;

            object raw;
            try
            {
                raw = serializer.DeserializeObject(requestText);
            }
            catch
            {
                return false;
            }

            IDictionary<string, object> root = raw as IDictionary<string, object>;
            if (root == null || root.Count != 3)
            {
                return false;
            }

            foreach (string key in root.Keys)
            {
                if (!String.Equals(key, "protocolVersion", StringComparison.Ordinal) &&
                    !String.Equals(key, "provider", StringComparison.Ordinal) &&
                    !String.Equals(key, "ids", StringComparison.Ordinal))
                {
                    return false;
                }
            }

            object protocolValue;
            if (!root.TryGetValue("protocolVersion", out protocolValue) ||
                !(protocolValue is int) ||
                (int)protocolValue != ProtocolVersion)
            {
                return false;
            }

            object providerValue;
            provider = root.TryGetValue("provider", out providerValue) ? providerValue as string : null;
            if (provider == null || !ProviderPattern.IsMatch(provider))
            {
                return false;
            }

            object idsValue;
            object[] rawIds = root.TryGetValue("ids", out idsValue) ? idsValue as object[] : null;
            if (rawIds == null || rawIds.Length == 0 || rawIds.Length > MaxRequestedIds)
            {
                return false;
            }

            HashSet<string> unique = new HashSet<string>(StringComparer.Ordinal);
            List<string> parsedIds = new List<string>(rawIds.Length);
            foreach (object rawId in rawIds)
            {
                string id = rawId as string;
                if (id == null || !CredentialIdPattern.IsMatch(id) || !unique.Add(id))
                {
                    return false;
                }
                parsedIds.Add(id);
            }

            ids = parsedIds;
            return true;
        }

        private static bool TryReadSecret(string id, out string value, out string error)
        {
            value = null;
            error = "unavailable";
            IntPtr credentialPointer = IntPtr.Zero;

            try
            {
                string target = CredentialTargetPrefix + id;
                if (!CredRead(target, CredentialTypeGeneric, 0, out credentialPointer))
                {
                    int nativeError = Marshal.GetLastWin32Error();
                    error = nativeError == ErrorNotFound ? "not found" : "unavailable";
                    return false;
                }

                if (credentialPointer == IntPtr.Zero)
                {
                    return false;
                }

                NativeCredential credential = (NativeCredential)Marshal.PtrToStructure(
                    credentialPointer,
                    typeof(NativeCredential));

                if (credential.Type != CredentialTypeGeneric ||
                    credential.CredentialBlob == IntPtr.Zero ||
                    credential.CredentialBlobSize == 0 ||
                    credential.CredentialBlobSize > MaxCredentialBytes)
                {
                    return false;
                }

                byte[] secretBytes = new byte[(int)credential.CredentialBlobSize];
                try
                {
                    Marshal.Copy(credential.CredentialBlob, secretBytes, 0, secretBytes.Length);
                    UTF8Encoding strictUtf8 = new UTF8Encoding(false, true);
                    value = strictUtf8.GetString(secretBytes);
                    if (value.Length == 0 || value.IndexOf('\0') >= 0)
                    {
                        value = null;
                        error = "not found";
                        return false;
                    }
                    return true;
                }
                catch (DecoderFallbackException)
                {
                    value = null;
                    return false;
                }
                finally
                {
                    Array.Clear(secretBytes, 0, secretBytes.Length);
                }
            }
            catch (Win32Exception)
            {
                value = null;
                return false;
            }
            finally
            {
                if (credentialPointer != IntPtr.Zero)
                {
                    CredFree(credentialPointer);
                }
            }
        }

        private static bool TryWriteBoundedResponse(IDictionary<string, object> response)
        {
            string json;
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                serializer.MaxJsonLength = MaxOutputBytes;
                serializer.RecursionLimit = 8;
                json = serializer.Serialize(response);
            }
            catch
            {
                return false;
            }

            byte[] output = Encoding.UTF8.GetBytes(json);
            try
            {
                if (output.Length > MaxOutputBytes)
                {
                    return false;
                }

                Stream stream = Console.OpenStandardOutput();
                stream.Write(output, 0, output.Length);
                stream.Flush();
                return true;
            }
            finally
            {
                Array.Clear(output, 0, output.Length);
            }
        }

        private static int Fail(string message)
        {
            try
            {
                Console.Error.WriteLine(message);
            }
            catch
            {
                // A closed stderr must not cause a second, potentially verbose failure.
            }
            return 2;
        }
    }
}
