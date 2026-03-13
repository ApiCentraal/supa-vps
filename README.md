# supa-vps
Een **productieklare all-in-one Supabase deployment & zero-downtime update script** voor **één VPS**, inclusief **multi-app support**, **Studio**, **multi-schema DB**, **NGINX + SSL**, **backups**, en **rollback functionaliteit**. Alles draait op dezelfde VPS, geen aparte database server.

---

### 🔹 Wat dit script doet

1. Creëert folders + storage per app.
2. Maakt `.env` met random keys.
3. Zet lokale PostgreSQL op met multi-schema (app1, app2, …) + RLS.
4. Docker Compose voor **blue containers** van Auth, Realtime, Storage, Studio.
5. NGINX met SSL + per-app subdomains.
6. Start containers.
7. Installeert Let's Encrypt SSL.
8. Cronjob voor dagelijkse DB-backups.
9. Functie `supabase_update()` voor **zero-downtime updates en rollback**.

---

💡 **Tips:**

* Nieuwe apps toevoegen → update `APPS` array en storage folder aanmaken.
* Voor updates: `supabase_update auth 1.16.0` → start green container, switch upstream, rollback mogelijk.
* Healthchecks kun je automatiseren met `/status` endpoints of Prometheus alerts.

---
