from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", case_sensitive=True, extra="ignore")

    # Fail-safe default: an unset ENVIRONMENT must NEVER enable dev backdoors
    # (master OTP, weak-key fallback, fake AWS clients). Local dev sets
    # ENVIRONMENT=local explicitly (.env / scripts/dev.sh / tests/conftest.py).
    ENVIRONMENT: Literal["local", "staging", "production"] = "production"

    DATABASE_URL: str
    REDIS_URL: str

    AWS_REGION: str = "us-east-1"
    AWS_ACCESS_KEY_ID: str = ""
    AWS_SECRET_ACCESS_KEY: str = ""
    AWS_S3_BUCKET_NAME: str = "doqto"

    # Push notifications — "log" is the dev stub ([FAKE PUSH] log lines);
    # "fcm" requires the FCM_* credentials below.
    PUSH_PROVIDER: Literal["log", "fcm"] = "log"
    FCM_PROJECT_ID: str = ""
    FCM_SERVICE_ACCOUNT_JSON: str = ""

    # Firebase is the identity broker for every sign-in method. Verification
    # needs only the project id — the ID token is checked against Google's
    # public certs, so there is no secret to hold here.
    FIREBASE_PROJECT_ID: str = ""

    JWT_SECRET: str
    MESSAGE_ENCRYPTION_KEY: str

    ALLOWED_ORIGINS: str = ""

    # Staged rollout (M3): gates CREATION of cross-org (different-org) direct
    # conversations between connected doctors. Same-org direct chats are NEVER
    # gated by this flag. Default True for local/test; PRODUCTION flips this to
    # false (NETWORK_DM_ENABLED=false in the prod env) until the networking
    # client ships, at which point it is turned on.
    NETWORK_DM_ENABLED: bool = True

    SUPER_ADMIN_PHONE: str = ""
    SUPER_ADMIN_NAME: str = ""
    SUPER_ADMIN_NPI: str = ""
    SUPER_ADMIN_EMAIL: str = ""
    SUPER_ADMIN_PASSWORD: str = ""

    @property
    def allowed_origins_list(self) -> list[str]:
        return [o.strip() for o in self.ALLOWED_ORIGINS.split(",") if o.strip()]

    @property
    def is_local(self) -> bool:
        return self.ENVIRONMENT == "local"


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]


settings = get_settings()
