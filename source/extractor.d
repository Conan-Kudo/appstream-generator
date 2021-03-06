/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

module ag.extractor;

import std.stdio;
import std.string;
import std.path : baseName;
import std.algorithm : canFind;
import appstream.Component;

import ag.config;
import ag.hint;
import ag.result;
import ag.backend.intf;
import ag.datacache;
import ag.handlers;


class DataExtractor
{

private:
    Component[] cpts;
    GeneratorHint[] hints;

    DataCache dcache;
    IconHandler iconh;
    Config conf;
    DataType dtype;

public:

    this (DataCache cache, IconHandler iconHandler)
    {
        dcache = cache;
        iconh = iconHandler;
        conf = Config.get ();
        dtype = conf.metadataType;
    }

    GeneratorResult processPackage (Package pkg)
    {
        // create a new result container
        auto gres = new GeneratorResult (pkg);

        // prepare a list of metadata files which interest us
        string[string] desktopFiles;
        string[] metadataFiles;
        foreach (ref fname; pkg.contents) {
            if ((fname.startsWith ("/usr/share/applications")) && (fname.endsWith (".desktop"))) {
                desktopFiles[baseName (fname)] = fname;
                continue;
            }
            if ((fname.startsWith ("/usr/share/metainfo")) && (fname.endsWith (".xml"))) {
                metadataFiles ~= fname;
                continue;
            }
            if ((fname.startsWith ("/usr/share/appdata")) && (fname.endsWith (".xml"))) {
                metadataFiles ~= fname;
                continue;
            }
        }

        // now process metainfo XML files
        foreach (ref mfname; metadataFiles) {
            if (!mfname.endsWith (".xml"))
                continue;

            auto dataBytes = pkg.getFileData (mfname);
            auto data = cast(string) dataBytes;
            auto cpt = parseMetaInfoFile (gres, data);
            if (cpt is null)
                continue;

            // check if we need to extend this component's data with data from its .desktop file
            auto cid = cpt.getId ();
            if (cid.empty) {
                gres.addHint ("general", "metainfo-no-id", ["fname": mfname]);
                continue;
            }

            // we need to add the version to re-download screenshot on every new upload.
            // otherwise, screenshots would only get updated if the actual metadata file was touched.
            gres.updateComponentGCID (cpt, pkg.ver);

            auto dfp = (cid in desktopFiles);
            if (dfp is null) {
                // no .desktop file was found
                // finalize GCID checksum and continue
                gres.updateComponentGCID (cpt, data);

                if (cpt.getKind () == ComponentKind.DESKTOP) {
                    // we have a DESKTOP_APP component, but no .desktop file. This is a bug.
                    gres.addHint (cpt.getId (), "missing-desktop-file");
                    continue;
                }

                // do a validation of the file. Validation is slow, so we allow
                // the user to disable this feature.
                if (conf.featureEnabled (GeneratorFeature.VALIDATE)) {
                    if (!dcache.metadataExists (dtype, gres.gcidForComponent (cpt)))
                        validateMetaInfoFile (cpt, gres, data);
                }
                continue;
            }

            // update component with .desktop file data, ignoring NoDisplay field
            auto ddataBytes = pkg.getFileData (*dfp);
            auto ddata = cast(string) ddataBytes;
            parseDesktopFile (gres, *dfp, ddata, true);

            // update GCID checksum
            gres.updateComponentGCID (cpt, ddata);

            // drop the .desktop file from the list, it has been handled
            desktopFiles.remove (cid);

            // do a validation of the file. Validation is slow, so we allow
            // the user to disable this feature.
            if (conf.featureEnabled (GeneratorFeature.VALIDATE)) {
                if (!dcache.metadataExists (dtype, gres.gcidForComponent (cpt)))
                    validateMetaInfoFile (cpt, gres, data);
            }
        }

        // process the remaining .desktop files
        foreach (ref dfname; desktopFiles.byValue ()) {
            auto ddataBytes = pkg.getFileData (dfname);
            auto ddata = cast(string) ddataBytes;
            auto cpt = parseDesktopFile (gres, dfname, ddata, false);
            if (cpt !is null)
                gres.updateComponentGCID (cpt, ddata);
        }

        foreach (ref cpt; gres.getComponents ()) {
            auto gcid = gres.gcidForComponent (cpt);

            // don't run expensive operations if the metadata already exists
            auto existingMData = dcache.getMetadata (dtype, gcid);
            if (existingMData !is null) {
                // To account for packages which change their package name, we
                // also need to check if the package this component is associated
                // with matches ours.
                // If it doesn't, we can't just link the package to the component.
                bool samePkg = false;
                if (dtype == DataType.YAML) {
                    if (existingMData.canFind (format ("Package: %s\n", pkg.name)))
                        samePkg = true;
                } else {
                    if (existingMData.canFind (format ("<pkgname>%s</pkgname>", pkg.name)))
                        samePkg = true;
                }

                if (!samePkg) {
                    import appstream.Metadata;
                    // The exact same metadata exists in a different package already, we emit an error hint.
                    // ATTENTION: This does not cover the case where *different* metadata (as in, different summary etc.)
                    // but with the *same ID* exists.
                    // We only catch that kind of problem later.

                    auto mdata = new Metadata ();
                    mdata.setParserMode (ParserMode.DISTRO);
                    if (dtype == DataType.YAML)
                        mdata.parseYaml (existingMData);
                    else
                        mdata.parseXml (existingMData);
                    auto ecpt = mdata.getComponent ();

                    gres.addHint (cpt.getId (), "metainfo-duplicate-id", ["cid": cpt.getId (), "pkgname": ecpt.getPkgnames ()[0]]);
                }

                continue;
            }

            // find & store icons
            iconh.process (gres, cpt);
            if (gres.isIgnored (cpt))
                continue;

            // download and resize screenshots.
            // we don't even need to call this if no downloads are allowed.
            if (!conf.featureEnabled (GeneratorFeature.NO_DOWNLOADS))
                processScreenshots (gres, cpt, dcache.mediaExportPoolDir);
        }

        // this removes invalid components and cleans up the result
        gres.finalize ();
        pkg.close ();

        return gres;
    }
}
