# MCP Manager

Application macOS native pour retrouver, configurer et gérer les serveurs MCP
des assistants intégrés à Xcode.

Projet expérimental sous [licence MIT](LICENSE). Version de développement :
`0.2.0-dev.1`. Aucune release publique n’est encore déclarée.

## Fonctionnalités

- Détection des configurations Xcode et import sélectif depuis les clients locaux.
- Catalogue de MCP avec recherche, sources officielles et ajout guidé.
- Installation, activation, désactivation et désinstallation par agent Xcode.
- Sauvegardes et historique de restauration des opérations de gestion.
- Variables d’environnement et secrets gérés via des profils et le Trousseau.
- Connexions STDIO/HTTP, découverte des outils, cache local et diagnostics.
- Premier parcours OAuth Sentry, interface français/anglais et surfaces Liquid Glass.

## Démarrer

Ouvrir `MCPManager.xcodeproj`, sélectionner le schéma MCPManager et My Mac,
puis compiler dans Xcode. La cible est macOS 14 ou ultérieur ; l’icône native a
été validée avec Xcode 27 beta 5. Les effets Liquid Glass nécessitent macOS 26,
avec un rendu de repli sur les versions antérieures.

Pour régénérer le projet avec XcodeGen :

```sh
xcodegen generate
open MCPManager.xcodeproj
```

## À savoir

- « Configuré » ne signifie pas « connecté » ni « chargé dans Xcode ». Une nouvelle
  conversation avec l’agent peut être nécessaire après modification.
- Les configurations de projet restent en lecture seule ; les écritures concernent
  les configurations globales des agents pris en charge.
- Le Manager ne partage pas la session OAuth de Xcode. Le parcours Sentry et les
  accès Trousseau restent à valider de bout en bout avec un compte réel.
- Les tokens HTTP gérés servent aux tests locaux, pas à leur transmission à Xcode.
- Les outils enregistrés restent consultables après déconnexion, sans preuve de
  connexion active. L’exécution `tools/call` n’est pas exposée dans l’interface.
- Le détail brut d’une erreur et les sauvegardes de configurations peuvent contenir
  des secrets : ne pas les publier. Aucun stockage en clair de secours ne remplace
  le Trousseau pour les secrets gérés.
- La lecture TOML reste partielle. La signature stable, la notarisation et la
  validation des mises à jour restent à finaliser avant distribution.

## Contribuer

Voir [CONTRIBUTING.md](CONTRIBUTING.md) pour la structure, les tests et les releases,
et [CHANGELOG.md](CHANGELOG.md) pour les changements.

## Sources et marques

Les recettes et leurs liens de documentation sont dans
`MCPManager/Resources/catalog.json`. « Officiel » décrit la provenance du serveur,
pas une garantie de compatibilité avec le Manager.

Les icônes de fournisseurs servent à les identifier ; leurs marques appartiennent
à leurs titulaires et n’impliquent aucune affiliation. La licence MIT du code ne
remplace pas leurs conditions d’utilisation, à vérifier avant distribution.

Sources des icônes embarquées :
[Context7](https://context7.com/favicon.ico),
[GitHub](https://github.githubassets.com/favicons/favicon.png),
[Sentry](https://sentry.io/favicon.ico) (conversion PNG),
[Figma](https://static.figma.com/app/icon/2/icon-128.png),
[RevenueCat](https://www.revenuecat.com/docs/img/favicon-32x32.png),
[Firebase](https://www.gstatic.com/devrel-devsite/prod/v5e941f15ff6710591bee254538202655020220785b40a3f4d932e94adb9f6037/firebase/images/touchicon-180.png),
[Supabase](https://supabase.com/favicon/favicon-128.png),
[Linear](https://linear.app/static/apple-touch-icon.png?v=2).
