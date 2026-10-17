# Publishing PugLogs

Everything is automated by `.github/workflows/release.yml`. To release a new version:

1. Raise `## Version:` in `PugLogs/PugLogs.toc` (e.g. `0.7.0` -> `0.7.1`) and commit.
2. Tag and push: `git tag v0.7.1 && git push && git push origin v0.7.1`

GitHub then builds the app (Windows installer + zip, macOS disk image), tests it, attaches it
to the release, and - once the steps below are done - uploads the addon to CurseForge and Wago.
The app tells its users when a new version is out.

---

## One-time setup: CurseForge (about 10 minutes, plus their review)

1. Log in (or sign up) at **https://authors.curseforge.com** with your CurseForge account.
2. **Create a project**: game **World of Warcraft**, class **Addons**.
   - Name: `PugLogs`
   - Summary: `Warcraft Logs runs for your Mythic+ applicants, right in the Group Finder.`
   - Description: paste `docs/curseforge-description.md`
   - Category: **Tooltip** (if extra categories are allowed: **Data Export** or **Miscellaneous**)
   - License: **MIT License**
   - Logo / avatar image: `docs/images/logo.png` (1024x1024; `logo-400.png` if a smaller one is needed)
   - Source: `https://github.com/roeescharf-sys/PugLogs`
3. Submit. CurseForge reviews new projects (usually a few hours to a few days).
4. On the project page, note the **Project ID** (shown in the "About Project" box).
5. Create an upload key: **https://legacy.curseforge.com/account/api-tokens** -> name it
   `PugLogs GitHub`, Generate, and copy the token. (If that page has moved, look for
   "API Tokens" in your CurseForge account settings.)
6. On GitHub: **https://github.com/roeescharf-sys/PugLogs/settings/secrets/actions**
   - **Secrets** tab -> New repository secret -> Name `CF_API_KEY`, value = the token.
   - **Variables** tab -> New repository variable -> Name `CURSEFORGE_PROJECT_ID`, value = the Project ID.

## One-time setup: Wago Addons (optional, about 5 minutes)

1. Log in at **https://addons.wago.io** (with Patreon, Discord, Battle.net, ...).
2. **Developer dashboard -> Create project**: name `PugLogs`, same summary/description.
3. Note the project's **ID** (in the project settings / URL).
4. Developer dashboard -> **API keys** -> create a key and copy it.
5. On GitHub (same page as above):
   - Secret `WAGO_API_TOKEN` = the key
   - Variable `WAGO_PROJECT_ID` = the project ID

## After that

The next tag you push also uploads the addon. To publish the current version right away
without changing anything: raise the version, tag and push as above.

Never put these keys in the repository itself - only in GitHub's Secrets.
