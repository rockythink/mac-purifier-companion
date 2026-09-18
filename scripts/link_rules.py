"""Pure temperature-link rules and ownership comparisons."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import math
from typing import Any, Literal

Phase = Literal["standby", "medium", "high"]


@dataclass(frozen=True)
class Config:
    mediumThreshold: float = 70.0
    highThreshold: float = 85.0
    downThreshold: float = 78.0
    exitThreshold: float = 63.0
    riseSeconds: float = 60.0
    fallSeconds: float = 180.0
    minAdjustSeconds: float = 60.0
    sampleSeconds: float = 20.0
    staleSeconds: float = 180.0
    mediumLevel: int | None = None
    highLevel: int | None = None

    @classmethod
    def from_dict(cls, values: dict[str, Any]) -> "Config":
        if not isinstance(values, dict):
            raise ValueError("配置必须是对象")
        expected = set(cls.__dataclass_fields__)
        unknown = set(values) - expected
        if unknown:
            raise ValueError(f"未知配置项：{', '.join(sorted(unknown))}")
        config = cls(**values)
        config.validate()
        return config

    def validate(self) -> None:
        numeric = (
            "mediumThreshold", "highThreshold", "downThreshold", "exitThreshold",
            "riseSeconds", "fallSeconds", "minAdjustSeconds", "sampleSeconds", "staleSeconds",
        )
        for name in numeric:
            value = getattr(self, name)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                raise ValueError(f"{name} 必须是有限数值")
        if not self.exitThreshold < self.mediumThreshold <= self.downThreshold < self.highThreshold:
            raise ValueError("温度阈值必须满足 exit < medium <= down < high")
        for name in ("riseSeconds", "fallSeconds", "sampleSeconds", "staleSeconds"):
            if getattr(self, name) <= 0:
                raise ValueError(f"{name} 必须大于 0")
        if self.minAdjustSeconds < 0:
            raise ValueError("minAdjustSeconds 不能小于 0")
        if self.sampleSeconds >= self.staleSeconds:
            raise ValueError("staleSeconds 必须大于 sampleSeconds")
        for name in ("mediumLevel", "highLevel"):
            value = getattr(self, name)
            if value is not None and (isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 17):
                raise ValueError(f"{name} 必须为空或 0–17 的整数")
        if self.mediumLevel is not None and self.highLevel is not None and self.mediumLevel >= self.highLevel:
            raise ValueError("中档必须低于高档")

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class Decision:
    target: Phase
    reason: str


class RuleEngine:
    """Evaluates dwell/hysteresis. Call ``commit`` only after an action succeeds."""

    def __init__(self, config: Config, phase: Phase = "standby") -> None:
        config.validate()
        self.config = config
        self.phase: Phase = phase
        self._since: dict[str, float] = {}
        self._last_now: float | None = None
        self._last_adjust: float | None = None

    def reset_dwell(self) -> None:
        self._since.clear()
        self._last_now = None
    def dwell(self) -> list[dict[str, float | str]]:
        """Return progress at the latest observed sample, never timer interpolation."""
        if self._last_now is None:
            return []
        required = {
            "high": self.config.riseSeconds,
            "medium": self.config.riseSeconds,
            "down": self.config.fallSeconds,
            "exit": self.config.fallSeconds,
        }
        return [
            {"name": name, "elapsed": max(0.0, self._last_now - started), "required": required[name]}
            for name, started in self._since.items()
            if name in required
        ]

    def update(self, temperature: float | None, now: float, *, valid: bool = True) -> Decision | None:
        if not math.isfinite(now):
            self.reset_dwell()
            return None
        if self._last_now is not None and (now < self._last_now or now - self._last_now > self.config.staleSeconds):
            self._since.clear()
        self._last_now = now
        if not valid or temperature is None or not math.isfinite(temperature):
            self._since.clear()
            return None

        conditions: list[tuple[str, bool, float, Phase, str]]
        if self.phase == "standby":
            conditions = [
                ("high", temperature >= self.config.highThreshold, self.config.riseSeconds, "high", "高温持续，计划进入高档"),
                ("medium", temperature >= self.config.mediumThreshold, self.config.riseSeconds, "medium", "温度持续升高，计划进入中档"),
            ]
        elif self.phase == "medium":
            conditions = [
                ("exit", temperature <= self.config.exitThreshold, self.config.fallSeconds, "standby", "低温持续，计划恢复接管前状态"),
                ("high", temperature >= self.config.highThreshold, self.config.riseSeconds, "high", "高温持续，计划进入高档"),
            ]
        else:
            conditions = [
                ("exit", temperature <= self.config.exitThreshold, self.config.fallSeconds, "standby", "低温持续，计划恢复接管前状态"),
                ("down", temperature <= self.config.downThreshold, self.config.fallSeconds, "medium", "温度持续下降，计划降至中档"),
            ]

        active = {name for name, met, *_ in conditions if met}
        for name in list(self._since):
            if name not in active:
                del self._since[name]
        for name, met, duration, target, reason in conditions:
            if not met:
                continue
            started = self._since.setdefault(name, now)
            if now - started < duration:
                continue
            is_restore = target == "standby"
            if not is_restore and self._last_adjust is not None and now - self._last_adjust < self.config.minAdjustSeconds:
                continue
            return Decision(target, reason)
        return None

    def commit(self, target: Phase, now: float) -> None:
        if target != self.phase:
            if target != "standby":
                self._last_adjust = now
            self.phase = target
        self._since.clear()
        self._last_now = now


def expected_device_state(power: bool, mode: str | None, level: int | None) -> dict[str, Any]:
    return {"power": power, "mode": mode, "level": level}


def still_owned(expected: dict[str, Any] | None, current: dict[str, Any]) -> bool:
    """RPM is intentionally excluded because it naturally varies."""
    if not expected:
        return False
    return all(current.get(key) == expected.get(key) for key in ("power", "mode", "level"))
