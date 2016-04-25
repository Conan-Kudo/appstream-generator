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

module ag.result;

import std.stdio;
import std.string;
import std.array : empty;
import std.conv : to;
import std.json;
import appstream.Component;

import ag.hint;
import ag.utils : buildCptGlobalID;
import ag.backend.intf;


class GeneratorResult
{

private:
    Component[string] cpts;
    string[Component] cptGCID;
    string[string] mdataHashes;
    HintList[string] hints;

public:
    string pkid;
    string pkgname;
    Package pkg;

public:

    this (Package pkg)
    {
        this.pkid = Package.getId (pkg);
        this.pkgname = pkg.name;
        this.pkg = pkg;
    }

    bool packageIsIgnored ()
    {
        return (cpts.length == 0) && (hints.length == 0);
    }

    Component getComponent (string id)
    {
        auto ptr = (id in cpts);
        if (ptr is null)
            return null;
        return *ptr;
    }

    Component[] getComponents ()
    {
        return cpts.values ();
    }

    bool isIgnored (Component cpt)
    {
        return getComponent (cpt.getId ()) is null;
    }

    void updateComponentGCID (Component cpt, string data)
    {
        import std.digest.md;

        auto cid = cpt.getId ();
        if (data.empty) {
            cptGCID[cpt] = buildCptGlobalID (cid, "???-NO_CHECKSUM-???");
            return;
        }

        auto oldHashP = (cid in mdataHashes);
        string oldHash = "";
        if (oldHashP !is null)
            oldHash = *oldHashP;

        auto hash = md5Of (oldHash ~ data);
        auto checksum = toHexString (hash);
        auto newHash = to!string (checksum);

        mdataHashes[cid] = newHash;
        cptGCID[cpt] = buildCptGlobalID (cid, newHash);
    }

    void addComponent (Component cpt, string data = "")
    {
        string cid = cpt.getId ();
        if (cid.empty)
            throw new Exception ("Can not add component without ID to results set.");

        cpt.setPkgnames ([this.pkgname]);
        cpts[cid] = cpt;
        updateComponentGCID (cpt, data);
    }

    void dropComponent (string cid)
    {
        auto cpt = getComponent (cid);
        if (cpt is null)
            return;
        cpts.remove (cid);
        cptGCID.remove (cpt);
    }

    /**
     * Add an issue hint to this result.
     * Params:
     *      cid    = The component-id this tag is assigned to.
     *      tag    = The hint tag.
     *      params = Dictionary of parameters to insert into the issue report.
     **/
    void addHint (string cid, string tag, string[string] params)
    {
        auto hint = new GeneratorHint (tag, cid);
        hint.setVars (params);
        if (cid is null)
            cid = "general";
        hints[cid] ~= hint;

        // we stop dealing with this component when we encounter a fatal
        // error.
        if (hint.isError ())
            dropComponent (cid);
    }

    /**
     * Add an issue hint to this result.
     * Params:
     *      cid = The component-id this tag is assigned to.
     *      tag = The hint tag.
     *      msg = An error message to add to the report.
     **/
    void addHint (string cid, string tag, string msg = null)
    {
        string[string] vars;
        if (msg !is null)
            vars = ["msg": msg];
        addHint (cid, tag, vars);
    }

    /**
     * Create JSON metadata for the hints found for the package
     * associacted with this GeneratorResult.
     */
    string hintsToJson ()
    {
        import std.stream;

        if (hints.length == 0)
            return null;

        // is this really the only way you can set a type for JSONValue?
        auto map = JSONValue (["null": 0]);
        map.object.remove ("null");

        foreach (cid; hints.byKey ()) {
            auto cptHints = hints[cid];
            auto hintNodes = JSONValue ([0, 0]);
            hintNodes.array = [];
            foreach (GeneratorHint hint; cptHints) {
                hintNodes.array ~= hint.toJsonNode ();
            }

            map.object[cid] = hintNodes;
        }

        auto root = JSONValue (["package": JSONValue (pkid), "hints": map]);
        return toJSON (&root, true);
    }

    /**
     * Drop invalid components and components with errors.
     */
    void finalize ()
    {
        // we need to duplicate the associative array, because the addHint() function
        // may remove entries from "cpts", breaking our foreach loop.
        foreach (cpt; cpts.dup.byValue ()) {
            auto ckind = cpt.getKind ();
            if (ckind == ComponentKind.DESKTOP) {
                // checks specific for .desktop and web apps
                if (cpt.getIcons ().len == 0)
                    addHint (cpt.getId (), "gui-app-without-icon");
            }
            if (ckind == ComponentKind.UNKNOWN)
                addHint (cpt.getId (), "metainfo-unknown-type");

            if ((!cpt.hasBundle ()) && (cpt.getPkgnames ().empty))
                addHint (cpt.getId (), "no-install-candidate");

            cpt.setActiveLocale ("C");
            if (cpt.getName ().empty)
                addHint (cpt.getId (), "metainfo-no-name");
            if (cpt.getSummary ().empty)
                addHint (cpt.getId (), "metainfo-no-summary");
        }

        // inject package descriptions, if needed
        foreach (cpt; cpts.byValue ()) {
            if (cpt.getKind () == ComponentKind.DESKTOP) {
                cpt.setActiveLocale ("C");
                if (cpt.getDescription ().empty) {
                    auto descP = "C" in pkg.description;
                    if (descP !is null) {
                        cpt.setDescription (*descP, "C");
                        addHint (cpt.getId (), "description-from-package");
                    }
                }
            }
        }
    }

    /**
     * Return the number of components we've found.
     **/
    ulong componentsCount ()
    {
        return cpts.length;
    }

    /**
     * Return the number of hints that have been emitted.
     **/
    ulong hintsCount ()
    {
        return hints.length;
    }

    string gcidForComponent (Component cpt)
    {
        auto cgp = (cpt in cptGCID);
        if (cgp is null)
            return null;
        return *cgp;
    }

    string[] getGCIDs ()
    {
        return cptGCID.values ();
    }

}

unittest
{
    import ag.backend.debian.debpkg;
    writeln ("TEST: ", "GeneratorResult");

    auto pkg = new DebPackage ("foobar", "1.0", "amd64");
    auto res = new GeneratorResult (pkg);

    auto vars = ["rainbows": "yes", "unicorns": "no", "storage": "towel"];
    res.addHint ("org.freedesktop.foobar.desktop", "just-a-unittest", vars);
    res.addHint ("org.freedesktop.awesome-bar.desktop", "metainfo-chocolate-missing", "Nothing is good without chocolate. Add some.");
    res.addHint ("org.freedesktop.awesome-bar.desktop", "metainfo-does-not-frobnicate", "Frobnicate functionality is missing.");

    writeln (res.hintsToJson ());
}
