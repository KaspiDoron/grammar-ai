# Publishing the Typfix extension

The extension installs locally with `scripts/install-editor-extension.sh`. To
make it installable from inside Cursor and VS Code by searching the
marketplace, publish it. This needs a free account and a token - steps below.
None of this is required to use the extension yourself.

## Open VSX (this is the one Cursor uses)

Cursor searches the [Open VSX Registry](https://open-vsx.org). To list Typfix
there so anyone can install it from Cursor's Extensions panel:

1. Create an account at https://open-vsx.org (sign in with GitHub).
2. Create a namespace matching the publisher `kaspidoron`:
   - Go to https://open-vsx.org/user-settings/namespaces and add `kaspidoron`.
3. Create an access token at https://open-vsx.org/user-settings/tokens.
4. Publish:
   ```bash
   cd editor-extension
   npm run build -- --minify
   npx ovsx publish grammar-ai.vsix -p <YOUR_OPEN_VSX_TOKEN>
   ```

After a few minutes it's searchable in Cursor: Extensions panel, search
"Typfix".

## VS Code Marketplace (for VS Code users)

1. Create a publisher at https://marketplace.visualstudio.com/manage
   (the publisher id must be `kaspidoron`, or change it in `package.json`).
2. Create a Personal Access Token in Azure DevOps with the Marketplace >
   Publish scope.
3. Publish:
   ```bash
   cd editor-extension
   npx @vscode/vsce publish -p <YOUR_AZURE_PAT>
   ```

## Notes

- Bump `version` in `package.json` before each publish.
- The icon, categories and keywords are already set for a good listing.
