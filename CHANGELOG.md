# Changelog

La numeracion es una reconstruccion documental del historial y de PRs fusionados. No existen tags semanticos oficiales.

La documentacion de fases se mantiene fuera de este repositorio.

## Sin publicar

### 0.4.1

- Ajustes posteriores de recursos, despliegue y consumidores.
- TODO: fijar commit y PR que definan 0.4.1.

## 0.4.0

- Orquestacion separada para frontend, backend, chatbot y proyeccion.
- Tres PostgreSQL, Redis, RabbitMQ y Ollama; cambios de memoria de Ollama documentados por los PRs #14 a #17.
- El compose de Testing asigna `5120m` a Ollama, segun los PRs #16 y #17.
- TODO: identificar el commit formal de release.

## 0.3.0

- Scripts de deploy, rollback, backups y base aislada de desarrollo.
- TODO: no hay tag que marque formalmente 0.3.0.

## 0.2.0

- Separacion de bases principal, vectorial y de usuarios, con RabbitMQ y Ollama.
- TODO: asociar la arquitectura a un commit exacto de 0.2.0.

## 0.1.0

- Base inicial de Docker Compose y despliegue del sistema.
- TODO: identificar el commit exacto que debe representar 0.1.0.
