# GitHub Desktop release setup

GitHub CLI is not required. The source repository is managed with **GitHub Desktop**, while compiled APKs are uploaded through the **GitHub Releases** page in a browser.

## Fix the current “Files too large” warning

Do **not** choose **Commit anyway**.

The file shown in the warning is a generated APK inside `archive/`. APK files, the entire `archive/` folder, Flutter build output, Gradle caches, IDE files, and private signing files are excluded by the updated root `.gitignore`.

1. Replace the root `.gitignore` with the updated file.
2. Return to GitHub Desktop and wait for it to refresh.
3. The generated APK/build files should disappear from the Changes list.
4. Review the remaining files before making the first commit.

When a generated file was already committed or tracked before the `.gitignore` update, open the repository terminal and remove only the affected paths from Git’s index while leaving them on disk:

```powershell
git rm -r --cached --ignore-unmatch archive output android_app/build android_app/.dart_tool android_app/android/.gradle android_app/android/.kotlin .idea
git rm --cached --ignore-unmatch android_app/android/key.properties android_app/android/upload-keystore.jks
git rm --cached --ignore-unmatch ":(glob)**/*.apk" ":(glob)**/*.aab" ":(glob)**/*.apks" ":(glob)**/*.zip"
```

Then return to GitHub Desktop, review the changes, commit, and push.

If a signing key was ever pushed publicly, removing it from the current commit is not enough; the repository history and key must be treated separately. This is not necessary when the warning appeared before the first commit and the files were never pushed.

## Publish the source with GitHub Desktop

1. In GitHub Desktop, choose **File → Add local repository**.
2. Select:

   ```text
   D:\Documents\extentions\spicychat-qol-android
   ```

3. Review the Changes list.
4. Confirm that none of these appear:
   - `archive/`
   - `output/`
   - `android_app/build/`
   - `.idea/`
   - any `.apk`
   - `key.properties`
   - `upload-keystore.jks`
5. Commit the source.
6. Choose **Publish repository** or **Push origin**.

## Prepare an Android release

Edit:

```text
release-notes.md
```

Then run:

```text
release_android.bat
```

This does not use GitHub CLI. It:

- synchronises the latest extension;
- increases the Android version;
- builds and signs the APK;
- creates `update.json` and `SHA256SUMS.txt`;
- gathers the upload files into:

  ```text
  output\release-upload\vVERSION
  ```

- opens that folder in File Explorer.

## Publish the release in your browser

After the build:

1. Use GitHub Desktop to commit and push the source/version changes.
2. Open the repository on GitHub.
3. Open **Releases**.
4. Choose **Draft a new release**.
5. Use the tag and title from `UPLOAD_INSTRUCTIONS.txt`.
6. Upload every file from the prepared release folder.
7. Publish the release.

Compiled APKs belong in **GitHub Releases**, not in the normal source commit.
