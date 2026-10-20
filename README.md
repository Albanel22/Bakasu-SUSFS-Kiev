# 🚀 BakaSU + SUSFS pour Motorola One 5G Ace (kiev) - Android 16

Ce dépôt contient le script de compilation (GitHub Actions) et les correctifs nécessaires pour faire tourner **BakaSU** avec **SUSFS v2.3.0** sur le **Motorola One 5G Ace** (nom de code : `kiev`) sous **LineageOS 23.2 (Android 16)** avec un noyau **4.19.325**.

> **Statut :** ✅ Testé et fonctionnel (Root OK, Modules OK, Seccomp désactivé).

---

## ✨ Caractéristiques
*   **Appareil :** Motorola One 5G Ace (SM7225 / lito)
*   **Noyau :** 4.19.325 (LineageOS 23.2)
*   **Gestionnaire :** BakaSU (branche `main`)
*   **Masquage :** SUSFS v2.3.0 (Patchs de JackA1ltman)
*   **Hooks :** Inline Hooks non-GKI (Méthode JackA1ltman)
*   **Contournement Seccomp :** Activé (via les hooks dans `kernel/sys.c` et `kernel/reboot.c`)

---

## 🛠️ Comment compiler (via GitHub Actions)

1. **Fork** ce dépôt.
2. Allez dans l'onglet **Actions** de votre fork.
3. Sélectionnez le workflow **"Build BakaSU Kernel"** (ou le nom de ton fichier .yml).
4. Cliquez sur **"Run workflow"**.
5. Une fois le build terminé (environ 1h), téléchargez l'artefact `BakaSU-SUSFS-boot.img` depuis la page du run.

---

## 📱 Comment flasher

1. Assurez-vous d'avoir le bootloader déverrouillé.
2. Redémarrez votre téléphone en mode **fastboot**.
3. Flashez l'image :
   ```bash
   fastboot flash boot BakaSU-SUSFS-boot.img
```

4. Redémarrez :
   ```bash
   fastboot reboot
   ```
5. Installez le Manager BakaSU (version v4.2.0-rc3 ou supérieure).
6. Ouvrez le Manager : il devrait afficher "En cours d'exécution" (Working) avec les modules et le root.

---

⚠️ Le piège à éviter (Important pour les développeurs)

Si vous essayez de modifier le script de compilation, ne patchez pas manuellement kernel/reboot.c ou kernel/sys.c avant d'appliquer les scripts de JackA1ltman.

Le script susfs_inline_hook_patches.sh vérifie la présence de ksu_handle dans les fichiers. S'il en trouve, il saute le fichier. Si vous injectez vos propres hooks manuellement, le script de JackA1ltman ignorera reboot.c et sys.c, ce qui empêchera le Manager de détecter le noyau.

Solution : Laissez le script de JackA1ltman injecter tous les hooks SUSFS. Ne les ajoutez pas vous-même.

---

🐛 Erreurs rencontrées et solutions (Troubleshooting)

Erreur Cause Solution
KernelSU driver install syscall was blocked by seccomp Android 16 bloque le syscall reboot pour les applications non privilégiées. Utiliser les inline hooks de JackA1ltman qui patchent kernel/sys.c et kernel/reboot.c pour contourner le blocage.
rm: missing operand Le script rm s'exécute alors qu'une variable est vide ou qu'un fichier n'existe pas. Ajouter `2>/dev/null
app_profile.c introuvable La structure des fichiers de BakaSU change selon la branche. Ce n'est pas grave si vous utilisez les inline hooks de JackA1ltman, qui gèrent tout.
Le Manager affiche "Non pris en charge" Les hooks de reboot et setuid ne sont pas appliqués correctement. Vérifier le log du build pour [+] kernel/reboot.c Patched! et [+] kernel/sys.c Patched!.

---

🙏 Crédits

· BakaSU pour le framework et le gestionnaire.
· JackA1ltman pour les patchs SUSFS non-GKI et le script d'inline hooks.
· backslashxx pour les recherches sur le contournement du seccomp.
· La communauté BakaSU sur Telegram pour les conseils techniques et le support.

---

📄 Licence

Ce projet est sous licence GPL-2.0 (comme le noyau Linux). Voir le fichier LICENSE pour plus de détails.
