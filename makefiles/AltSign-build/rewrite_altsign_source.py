#!/usr/bin/python3

import re
import sys

F = sys.argv[1]

with open(F, 'rb') as f:
    content = f.read()

content = re.sub(br'L("([^"\\]|\\.)*")', br'U(\1)', content)
content = content.replace(b'std::wstring', b'std::string')
content = content.replace(b'boost/filesystem.hpp', b'filesystem')
content = content.replace(b'boost::filesystem', b'std::filesystem')

content = content.replace(b'"%FT%T%z"', b'"%Y-%m-%dT%H:%M:%SZ"')
content = content.replace(b'localtime(', b'gmtime(')

content = content.replace(b'winsock2.h', b'WinSock2.h')

# iOS 26 fix: sign the prepared app bundle with rcodesign instead of ldid. ldid's bundle signature
# (CodeResources/CMS) is rejected by iOS 26's TXM; rcodesign produces a valid modern signature.
# Requires `rcodesign` (path via $ALTSERVER_RCODESIGN, default "rcodesign") and `openssl` at runtime.
if F.endswith('Signer.cpp'):
    content = content.replace(b'#include "Signer.hpp"',
                              b'#include "Signer.hpp"\n#include <cstdlib>\n#include <stdexcept>', 1)
    _rcodesign_block = br'''// iOS 26: sign the prepared bundle with rcodesign (ldid's bundle signature is rejected on iOS 26).
        {
            fs::path rcTmp = fs::temp_directory_path() / make_uuid();
            fs::create_directories(rcTmp);
            fs::path p12Path = rcTmp / "key.p12";
            fs::path pemPath = rcTmp / "key.pem";
            fs::path entPath = rcTmp / "ents.xml";
            { std::ofstream kf(p12Path.string(), std::ios::out | std::ios::binary); kf.write(key.data(), (std::streamsize)key.size()); }
            std::string mainEntitlements = entitlementsByFilepath[app.path()];
            { std::ofstream ef(entPath.string(), std::ios::out | std::ios::binary); ef.write(mainEntitlements.data(), (std::streamsize)mainEntitlements.size()); }

            std::string toPem = "openssl pkcs12 -legacy -nomacver -nodes -passin pass: -in '" + p12Path.string() + "' -out '" + pemPath.string() + "' 2>/dev/null";
            if (system(toPem.c_str()) != 0) { fs::remove_all(rcTmp); throw std::runtime_error("rcodesign: failed to convert signing key to PEM (need openssl)"); }

            const char* rcEnv = getenv("ALTSERVER_RCODESIGN");
            std::string rcodesign = (rcEnv && *rcEnv) ? std::string(rcEnv) : std::string("rcodesign");
            std::string cmd = "'" + rcodesign + "' sign --pem-file '" + pemPath.string() + "' --entitlements-xml-file '" + entPath.string() + "' '" + app.path() + "'";
            odslog("rcodesign signing: " << cmd);
            int rc = system(cmd.c_str());
            fs::remove_all(rcTmp);
            if (rc != 0) throw std::runtime_error("rcodesign signing failed (set ALTSERVER_RCODESIGN to its path)");
        }'''
    content = re.sub(br'ldid::Sign\("", appBundle, key, "",.*?signingProgress\);\s*\n\s*\}\)\);',
                     lambda m: _rcodesign_block, content, count=1, flags=re.S)

sys.stdout.buffer.write(content)