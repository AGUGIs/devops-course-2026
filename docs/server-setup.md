# Настройка учебного сервера

## 10. Ansible

Проект находится в `ansible/`. Управляющий узел запускает Ansible, управляемый узел — Ubuntu Server 24.04 amd64 с SSH. Для своей ВМ установите её фактический адрес и порт в двух inventory.

- `inventory/bootstrap.ini` — первичный вход пользователем `student`; пароль вводится интерактивно.
- `inventory/prod.ini` — вход пользователем `devops` с локальным SSH-ключом.
- `base` устанавливает базовые пакеты и Docker Engine из официального репозитория.
- `ssh` устанавливает открытый ключ, проверяет sudoers и SSH, затем включает UFW.
- `nginx` управляет reverse proxy на порту 80, проверяет конфигурацию перед reload.
- `app` получает образ GHCR по SHA и запускает контейнер с привязкой `127.0.0.1:5000:5000`.

Образ: `ghcr.io/agugis/devops-ci-app:492f50258334b0e2a4953755d8c16564816f299c`. Проверка приложения: `/health`.

```sh
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory/bootstrap.ini site.yml --ask-pass --ask-become-pass
ansible-playbook site.yml
ansible-playbook verify.yml
```

Рабочие пароли и закрытые ключи хранятся через локальный SSH или средства управления секретами. Для стендовой проверки workflow запускает изолированную временную ВМ и генерирует отдельные одноразовые учётные данные. Сценарий стенда проверяет bootstrap, идемпотентность, восстановление drift, отказ pull и аудит.
