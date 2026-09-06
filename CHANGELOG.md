# Journal des changements

## Non publié — préparation du dépôt

- Noms de projets personnels remplacés par des noms génériques dans les fixtures avant publication.
- Documentation limitée à README, CONTRIBUTING et CHANGELOG ; autres documents conservés uniquement en notes locales ignorées.
- Licence MIT, CI macOS et workflow de releases brouillon de sources à partir de tags annotés.
- Version centralisée dans Config/Version.xcconfig ; contrôles de cohérence tag/version/changelog et documentation de publication.
- Aucune release, aucun tag et aucun binaire de distribution publiés dans ce lot.

## Non publié — 2026-09-05

### Structure

- Superviseur séparé de la session MCP, de la pagination et de la politique de diagnostic ; dépendances injectables et scénarios de concurrence synthétiques.
- Actualisations concurrentes dédupliquées, résultats et erreurs tardifs rejetés après arrêt/remplacement, cache dévérifié à la sortie du processus. Fermeture normale de l’app : annulation et fermeture des sessions du Manager.
- Textes des vues regroupés dans des extensions privées avec enum Constants, constantes statiques et fonctions d’interpolation ; table xcstrings existante conservée.
- Localisation des journaux dynamiques, du parseur et des erreurs publiques du lanceur ; résolution testée des traductions de son app parente.
- Audit automatisé de couverture FR/EN et des interpolations ; pluriels accessibles de la sidebar corrigés.
- Éditeur de serveur et formulaire de secrets séparés de leur logique ; tests d’annulation, d’échec et de sauvegardes concurrentes.
- Huit recettes du catalogue et principaux diagnostics métier traduits ; recherche sur les textes source et localisés.
- Extraction de ManagerViewModel, XcodeInstallationViewModel et CatalogViewModel ; tests synthétiques de présentation.
- Catalogue de chaînes natif français/anglais, pluriels et contrôle des ressources compilées. Recette visuelle exhaustive restant à effectuer.
- Vues organisées en Navigation, Catalog, Server, Authentication, Xcode, Discovery et Components.
- Extraction de MCPServerSidebar, ServerRow, MCPCatalogCard, ToolDisclosure et StatusBadge.
- Contrats documentés pour la navigation, l’installation, le superviseur et les profils d’environnement.
- Guides architecture, contribution et sécurité, suivi identifié et contrôle autonome du catalogue.

### Fonctionnalités déjà présentes

- Catalogue de huit MCP officiels avec icônes locales et sources.
- Icône native Icon Composer intégrée ; recherche du catalogue compacte.
- Variables accessibles depuis le diagnostic d’installation et confirmation des avertissements.

Les comptes réels, la signature et certains parcours Trousseau restent à valider avant distribution.
