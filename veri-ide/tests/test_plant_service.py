"""
Tests for plant model management service.
"""
import pytest
import tempfile
from pathlib import Path

from veri_ide.backend.sim.plant import (
    RAW_MAX,
    RAW_MIN,
    PlantChannel,
    PlantModel,
    PlantService,
    PlantValidationError,
    ChannelDir,
    ChannelKind,
    plant_from_external_variables,
)


class TestPlantChannel:
    """Tests for PlantChannel."""

    def test_to_plant_line(self):
        """Test converting channel to plant line."""
        ch = PlantChannel(
            channel_id=0,
            dir=ChannelDir.INPUT,
            kind=ChannelKind.LAG,
            gain=0.125,
            offset=0,
            min_val=0,
            max_val=1000,
            init_val=0,
            drive=1,
        )
        line = ch.to_plant_line()
        assert line == "0 INPUT LAG 0.125 0 0 1000 0 1"

    def test_to_dict(self):
        """Test converting channel to dict."""
        ch = PlantChannel(
            channel_id=1,
            dir=ChannelDir.OUTPUT,
            kind=ChannelKind.ACTUATOR,
            gain=0,
            offset=0,
            min_val=0,
            max_val=1000,
            init_val=0,
            drive=-1,
        )
        d = ch.to_dict()
        assert d["channel_id"] == 1
        assert d["dir"] == "OUTPUT"
        assert d["kind"] == "ACTUATOR"

    def test_from_dict(self):
        """Test creating channel from dict."""
        d = {
            "channel_id": 2,
            "dir": "INPUT",
            "kind": "CONST",
            "gain": 0,
            "offset": 0,
            "min_val": 0,
            "max_val": 1000,
            "init_val": 500,
            "drive": -1,
        }
        ch = PlantChannel.from_dict(d)
        assert ch.channel_id == 2
        assert ch.dir == ChannelDir.INPUT
        assert ch.kind == ChannelKind.CONST


class TestPlantModel:
    """Tests for PlantModel."""

    def test_to_plant_text(self):
        """Test converting model to plant text."""
        model = PlantModel(
            name="test",
            description="Test plant",
            channels=[
                PlantChannel(
                    channel_id=0,
                    dir=ChannelDir.INPUT,
                    kind=ChannelKind.CONST,
                    gain=0,
                    offset=0,
                    min_val=0,
                    max_val=1000,
                    init_val=500,
                    drive=-1,
                ),
            ],
        )
        text = model.to_plant_text()
        assert "# Plant model: test" in text
        assert "# Test plant" in text
        assert "0 INPUT CONST 0 0 0 1000 500 -1" in text

    def test_to_dict_from_dict(self):
        """Test round-trip conversion."""
        model = PlantModel(
            name="test",
            description="Test",
            channels=[
                PlantChannel(
                    channel_id=0,
                    dir=ChannelDir.INPUT,
                    kind=ChannelKind.LAG,
                    gain=0.5,
                    offset=10,
                    min_val=0,
                    max_val=100,
                    init_val=50,
                    drive=1,
                ),
            ],
        )
        d = model.to_dict()
        model2 = PlantModel.from_dict(d)
        assert model2.name == model.name
        assert len(model2.channels) == 1
        assert model2.channels[0].gain == 0.5


class TestPlantService:
    """Tests for PlantService."""

    def test_parse_plant_file(self):
        """Test parsing a .plant file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            plant_file = Path(tmpdir) / "test.plant"
            plant_file.write_text(
                "# Test plant\n"
                "0 INPUT LAG 0.125 0 0 1000 0 1\n"
                "1 OUTPUT ACTUATOR 0 0 0 1000 0 -1\n"
            )

            service = PlantService()
            model = service.parse_plant_file(plant_file)

            assert model.name == "test"
            assert len(model.channels) == 2
            assert model.channels[0].kind == ChannelKind.LAG
            assert model.channels[1].dir == ChannelDir.OUTPUT

    def test_parse_plant_file_not_found(self):
        """Test parsing non-existent file."""
        service = PlantService()
        with pytest.raises(PlantValidationError, match="not found"):
            service.parse_plant_file("/nonexistent.plant")

    def test_parse_plant_file_malformed(self):
        """Test parsing malformed file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            plant_file = Path(tmpdir) / "bad.plant"
            plant_file.write_text("0 INPUT LAG 0.125\n")  # Missing fields

            service = PlantService()
            with pytest.raises(PlantValidationError, match="expected 9 fields"):
                service.parse_plant_file(plant_file)

    def test_validate_plant_model_valid(self):
        """Test validating a valid model."""
        model = PlantModel(
            name="test",
            channels=[
                PlantChannel(
                    channel_id=0,
                    dir=ChannelDir.INPUT,
                    kind=ChannelKind.LAG,
                    gain=0.125,
                    offset=0,
                    min_val=0,
                    max_val=1000,
                    init_val=0,
                    drive=1,
                ),
                PlantChannel(
                    channel_id=1,
                    dir=ChannelDir.OUTPUT,
                    kind=ChannelKind.ACTUATOR,
                    gain=0,
                    offset=0,
                    min_val=0,
                    max_val=1000,
                    init_val=0,
                    drive=-1,
                ),
            ],
        )

        service = PlantService()
        errors = service.validate_plant_model(model)
        assert errors == []

    def test_validate_plant_model_duplicate_ids(self):
        """Test validation catches duplicate channel IDs."""
        model = PlantModel(
            name="test",
            channels=[
                PlantChannel(
                    channel_id=0,
                    dir=ChannelDir.INPUT,
                    kind=ChannelKind.CONST,
                    gain=0,
                    offset=0,
                    min_val=0,
                    max_val=1000,
                    init_val=500,
                    drive=-1,
                ),
                PlantChannel(
                    channel_id=0,  # Duplicate!
                    dir=ChannelDir.INPUT,
                    kind=ChannelKind.CONST,
                    gain=0,
                    offset=0,
                    min_val=0,
                    max_val=1000,
                    init_val=500,
                    drive=-1,
                ),
            ],
        )

        service = PlantService()
        errors = service.validate_plant_model(model)
        assert any("Duplicate" in e for e in errors)

    def test_validate_plant_model_output_not_actuator(self):
        """Test validation catches OUTPUT with non-ACTUATOR kind."""
        model = PlantModel(
            name="test",
            channels=[
                PlantChannel(
                    channel_id=0,
                    dir=ChannelDir.OUTPUT,
                    kind=ChannelKind.LAG,  # Wrong!
                    gain=0.5,
                    offset=0,
                    min_val=0,
                    max_val=1000,
                    init_val=0,
                    drive=-1,
                ),
            ],
        )

        service = PlantService()
        errors = service.validate_plant_model(model)
        assert any("OUTPUT must be ACTUATOR" in e for e in errors)

    def test_validate_plant_model_lag_gain_out_of_range(self):
        """Test validation catches LAG gain outside (0, 1]."""
        model = PlantModel(
            name="test",
            channels=[
                PlantChannel(
                    channel_id=0,
                    dir=ChannelDir.INPUT,
                    kind=ChannelKind.LAG,
                    gain=1.5,  # Out of range!
                    offset=0,
                    min_val=0,
                    max_val=1000,
                    init_val=0,
                    drive=-1,
                ),
            ],
        )

        service = PlantService()
        errors = service.validate_plant_model(model)
        assert any("LAG gain" in e for e in errors)

    def test_validate_plant_model_init_out_of_range(self):
        """Test validation catches init outside [min, max]."""
        model = PlantModel(
            name="test",
            channels=[
                PlantChannel(
                    channel_id=0,
                    dir=ChannelDir.INPUT,
                    kind=ChannelKind.CONST,
                    gain=0,
                    offset=0,
                    min_val=0,
                    max_val=100,
                    init_val=150,  # Out of range!
                    drive=-1,
                ),
            ],
        )

        service = PlantService()
        errors = service.validate_plant_model(model)
        assert any("init" in e and "outside" in e for e in errors)

    def test_save_and_load_plant_model(self):
        """Test saving and loading plant model."""
        with tempfile.TemporaryDirectory() as tmpdir:
            service = PlantService(storage_dir=tmpdir)

            model = PlantModel(
                name="test_model",
                description="Test",
                channels=[
                    PlantChannel(
                        channel_id=0,
                        dir=ChannelDir.INPUT,
                        kind=ChannelKind.CONST,
                        gain=0,
                        offset=0,
                        min_val=0,
                        max_val=1000,
                        init_val=500,
                        drive=-1,
                    ),
                ],
            )

            service.save_plant_model(model)
            loaded = service.load_plant_model("test_model")

            assert loaded.name == model.name
            assert len(loaded.channels) == 1
            assert loaded.channels[0].init_val == 500

    def test_list_plant_models(self):
        """Test listing plant models."""
        with tempfile.TemporaryDirectory() as tmpdir:
            service = PlantService(storage_dir=tmpdir)

            model1 = PlantModel(name="model1", channels=[])
            model2 = PlantModel(name="model2", channels=[])

            service.save_plant_model(model1)
            service.save_plant_model(model2)

            models = service.list_plant_models()
            assert "model1" in models
            assert "model2" in models

    def test_delete_plant_model(self):
        """Test deleting plant model."""
        with tempfile.TemporaryDirectory() as tmpdir:
            service = PlantService(storage_dir=tmpdir)

            model = PlantModel(name="to_delete", channels=[])
            service.save_plant_model(model)

            assert service.delete_plant_model("to_delete")
            assert not service.delete_plant_model("to_delete")  # Already deleted

    def test_create_closed_loop_plant(self):
        """Test creating default closed-loop plant."""
        service = PlantService()
        model = service.create_closed_loop_plant()

        assert model.name == "closed_loop"
        assert len(model.channels) == 3

        errors = service.validate_plant_model(model)
        assert errors == []


def _point(name, direction, st_type, channel, **kwargs):
    row = {
        "name": name,
        "direction": direction,
        "st_type": st_type,
        "mapped": channel is not None,
        "channel": channel,
        "safety_min": None,
        "safety_max": None,
        "fault_hold": "",
        "preset_value": None,
    }
    row.update(kwargs)
    return row


class TestPlantFromStationConfig:
    """The station's point table is the object table's only source."""

    def test_inputs_hold_and_outputs_echo(self):
        model = plant_from_external_variables("ST1", [
            _point("SW_A", "input", "BOOL", 12),
            _point("PUMP", "output", "BOOL", 20),
        ])
        assert [ch.to_plant_line() for ch in model.channels] == [
            "12 INPUT CONST 0 0 0 1 0 -1",
            "20 OUTPUT ACTUATOR 0 0 0 1 0 -1",
        ]
        assert PlantService().validate_plant_model(model) == []

    def test_limits_and_fault_preset_come_from_the_point(self):
        model = plant_from_external_variables("ST1", [
            _point("PV", "input", "DINT", 0, safety_min=0, safety_max=1000,
                   fault_hold="preset", preset_value=250.4),
            _point("ACT", "output", "DINT", 8, safety_min=0, safety_max=1000),
        ])
        pv, act = model.channels
        assert (pv.min_val, pv.max_val, pv.init_val) == (0, 1000, 250)
        assert (act.min_val, act.max_val, act.init_val) == (0, 1000, 0)

    def test_unconfigured_analogue_gets_the_whole_raw_window(self):
        """No limits means nothing to clamp, not an invented range."""
        model = plant_from_external_variables("ST1", [_point("SP", "input", "DINT", 2)])
        assert (model.channels[0].min_val, model.channels[0].max_val) == (RAW_MIN, RAW_MAX)

    def test_unmapped_variables_are_left_out(self):
        """They declare storage but reach no channel, so no row can name one."""
        model = plant_from_external_variables("ST1", [
            _point("SW_A", "input", "BOOL", 12),
            _point("UNUSED", "input", "BOOL", None),
        ])
        assert [ch.channel_id for ch in model.channels] == [12]

    def test_a_table_that_cannot_be_simulated_is_refused(self):
        for rows in ([], [_point("SW_A", "input", "BOOL", None)]):
            with pytest.raises(PlantValidationError):
                plant_from_external_variables("ST1", rows)

    def test_two_points_on_one_channel_are_refused(self):
        with pytest.raises(PlantValidationError, match="bound by both"):
            plant_from_external_variables("ST1", [
                _point("A", "input", "DINT", 0),
                _point("B", "input", "DINT", 0),
            ])

    def test_inverted_limits_are_refused(self):
        with pytest.raises(PlantValidationError, match="safety_min"):
            plant_from_external_variables("ST1", [
                _point("A", "input", "DINT", 0, safety_min=500, safety_max=100),
            ])
