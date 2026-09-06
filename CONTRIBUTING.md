# Contribuer à MCP Manager

## Organisation

- `MCPManager/Views` : rendu et interactions, regroupés par fonctionnalité.
- `MCPManager/ViewModels` : état et logique de présentation.
- `MCPManager/Models` et `Services` : données, règles métier, connexions et stockage.
- `Shared` et `MCPEnvironmentLauncher` : profils et lanceur embarqué.
- `MCPManagerTests` et `scripts` : tests et contrôles synthétiques.

`project.yml` définit le projet ; `Config/Version.xcconfig` définit sa version.
Après un ajout de fichier, exécuter `xcodegen generate` et inclure le projet généré.
L’icône est dans `Design/MCPManagerIcon.icon`. En cas d’échec de son export en
ligne de commande, vérifier la compilation dans Xcode.

## Conventions

- Une branche courte et une PR vers `main` par changement cohérent.
- Séparer la logique des vues ; expliquer les invariants sensibles avec `///`.
- Placer les textes des vues dans un `enum Constants` en extension privée :
  `static let` pour les libellés fixes, fonctions typées pour les interpolations.
  Les traductions FR/EN et pluriels sont dans `Localizable.xcstrings`.
- Ne pas traduire commandes, clés de configuration, noms utilisateur ou réponses
  distantes. Les constantes localisées nécessitent un relancement après changement
  de langue.
- Ne jamais ajouter de tokens, configurations personnelles, certificats, builds
  ou captures non expurgées. Utiliser des fixtures synthétiques.
- Ne garder comme documents Markdown que README, CONTRIBUTING et CHANGELOG.
  Les notes de travail locales vont dans `.local-notes/`, ignoré par Git.

## Vérifier

```sh
bash scripts/check-catalog.sh
bash scripts/check-presentation.sh
bash scripts/check-supervisor.sh
ruby scripts/check-localization.rb
ruby scripts/check-release.rb
ruby scripts/test-release.rb
```

Ces contrôles n’utilisent pas de compte réel. L’audit de localisation doit suivre
un build Xcode pour intégrer l’extraction des nouveaux textes.
Pour XCTest : Product → Test dans Xcode. Un build réussi ne prouve pas l’exécution
des tests. Pour l’interface, vérifier les deux langues, clair/sombre, clavier,
fenêtre étroite, erreurs et annulation.

Dans la PR, décrire l’objectif, les risques et migrations, les tests effectivement
exécutés et les limites restantes. Mettre à jour CHANGELOG si pertinent.
Ne jamais publier un secret pour signaler un problème ; expurger les diagnostics.

## Versioning et releases

- SemVer : `0.2.0-beta.1`, `0.2.0-rc.1`, puis `0.2.0`.
- Mettre à jour RELEASE_VERSION, MARKETING_VERSION (X.Y.Z sans suffixe) et augmenter
  CURRENT_PROJECT_VERSION dans `Config/Version.xcconfig`.
- Ajouter une section datée `## [VERSION] — YYYY-MM-DD` au CHANGELOG.
- Vérifier avec `ruby scripts/check-release.rb vVERSION`, puis faire relire et
  fusionner la PR. Les versions `-dev.N` ne peuvent pas être livrées.
- Sur un checkout propre de main à jour, créer un tag annoté, puis pousser ce tag
  uniquement. Exemple à adapter, non exécuté automatiquement :

```sh
git tag -a v0.2.0-beta.1 -m "MCP Manager 0.2.0-beta.1"
git push origin v0.2.0-beta.1
```

Ne jamais déplacer un tag publié ni utiliser un push forcé pour une release.
Le workflow vérifie les tests, le tag annoté, son appartenance à main et la
cohérence version/changelog avant de créer un **brouillon de release de sources**.
Les préversions sont marquées comme telles ; la publication reste manuelle.
Un nouveau lancement ne remplace pas une release existante.

La CI macOS exécute les scénarios synthétiques et la localisation, pas encore
le build natif Icon Composer ni toute la suite XCTest. Les workflows restent à
valider sur GitHub. Configurer les protections de main et des tags côté GitHub.

Avant de distribuer un binaire : identité de bundle durable, signature Developer ID
de l’app et du lanceur, notarisation, ticket agrafé, archive avec SHA-256, tests
Gatekeeper/Trousseau et de mise à jour. Auditer aussi les données personnelles,
l’historique Git et les droits des ressources tierces.
