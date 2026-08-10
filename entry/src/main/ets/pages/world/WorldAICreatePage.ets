import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldAICreateViewModel,
  SelectedCharacterItem,
  WorldAICreateStage,
  AiGeneratedWorldPreview
} from '../../viewmodels/world/WorldAICreateViewModel';
import { CharacterImageView } from '../../components/CharacterImageView';
import { ThemePalette } from '../../theme/ThemePalette';

@Entry
@Component
struct WorldAICreatePage {
  @State vm: WorldAICreateViewModel | null = null;
  @State characters: SelectedCharacterItem[] = [];
  @State stage: WorldAICreateStage = WorldAICreateStage.SelectCharacters;
  @State worldTheme: string = '';
  @State isGenerating: boolean = false;
  @State generationError: string = '';
  @State preview: AiGeneratedWorldPreview | null = null;
  @State isSaving: boolean = false;
  @State saveError: string = '';
  @State playerDisplayName: string = '';
  @State playerNameError: string = '';
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  aboutToAppear(): void {
    AppServices.whenReady().then((): void => {
      const ws = AppServices.getWorldStateService();
      const cs = AppServices.getCharacterService();
      const ms = AppServices.getModelService();
      if (ws === null || cs === null || ms === null) {
        return;
      }
      const v: WorldAICreateViewModel = new WorldAICreateViewModel(ws, cs, ms);
      this.vm = v;
      v.loadCharacters().then((): void => {
        this.syncFromVM();
      });
    });
  }

  syncFromVM(): void {
    if (this.vm === null) { return; }
    this.characters = this.vm.characters;
    this.stage = this.vm.stage;
    this.isGenerating = this.vm.isGenerating;
    this.generationError = this.vm.generationError;
    this.preview = this.vm.preview;
    this.isSaving = this.vm.isSaving;
    this.saveError = this.vm.saveError;
    this.playerNameError = this.vm.playerNameError;
    if (this.vm.saveSucceeded) {
      promptAction.showToast({ message: $r('app.string.world_create_success'), duration: 1500 });
      router.back();
    }
  }

  goBack(): void {
    if (this.vm !== null) { this.vm.dispose(); }
    router.back();
  }

  build(): void {
    Column() {
      this.headerBar()
      if (this.stage === WorldAICreateStage.SelectCharacters) {
        this.charSelectView()
      } else if (this.stage === WorldAICreateStage.InputTheme) {
        this.themeView()
      } else if (this.stage === WorldAICreateStage.Generating) {
        this.genView()
      } else if (this.stage === WorldAICreateStage.Review) {
        this.reviewView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder headerBar(): void {
    Row() {
      Button('<')
        .fontSize(22)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .width(44)
        .height(44)
        .onClick(() => { this.goBack(); })
      Text($r('app.string.world_ai_create_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .layoutWeight(1)
      Blank()
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder charSelectView(): void {
    Column() {
      Text($r('app.string.world_ai_select_chars_hint'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 4 })

      Text((this.vm !== null ? this.vm.selectedCount.toString() : '0') + $r('app.string.world_ai_selected_count'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

      List() {
        ForEach(this.characters, (item: SelectedCharacterItem, index: number) => {
          ListItem() {
            Row() {
              CharacterImageView({
                imageUri: item.character.avatarUri,
                fallbackName: item.character.name,
                imgWidth: 44,
                imgHeight: 44,
                imgBorderRadius: 22,
                displayMode: 'thumbnail'
              })

              Column() {
                Text(item.character.name)
                  .fontSize($r('app.float.app_font_body'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                  .maxLines(1)
                Text(item.character.description.length > 0
                  ? item.character.description : $r('app.string.world_no_description'))
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .margin({ left: 12 })
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Checkbox, isOn: item.selected })
                .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
                .onChange((_isOn: boolean) => {
                  this.vm!.toggleCharacter(index);
                  this.syncFromVM();
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
          }
        }, (_item: SelectedCharacterItem, index: number): string => index.toString())
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

      Row() {
        Button($r('app.string.world_ai_next_theme'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(48)
          .layoutWeight(1)
          .enabled(this.vm !== null && this.vm.canGenerate())
          .onClick(() => {
            this.vm!.goToThemeInput();
            this.syncFromVM();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder themeView(): void {
    Column() {
      Text($r('app.string.world_ai_theme_hint'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      TextInput({ text: this.worldTheme, placeholder: $r('app.string.world_ai_theme_placeholder') })
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .width('100%')
        .height(48)
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.worldTheme = v;
          if (this.vm !== null) { this.vm.worldTheme = v; }
        })

      Blank()

      if (this.generationError.length > 0) {
        Text(this.generationError)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.world_error'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16, bottom: 8 })
      }

      Row() {
        Button($r('app.string.world_ai_back_select'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(48)
          .layoutWeight(1)
          .margin({ right: 8 })
          .onClick(() => {
            if (this.vm !== null) { this.vm.goBackToSelect(); this.syncFromVM(); }
          })

        Button($r('app.string.world_ai_generate'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(48)
          .layoutWeight(1)
          .enabled(!this.isGenerating)
          .onClick(() => {
            if (this.vm !== null) {
              this.vm.generateWorld().then((): void => { this.syncFromVM(); });
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder genView(): void {
    Column() {
      LoadingProgress().width(48).height(48)
        .color(ThemePalette.accentColor(this.effectiveTheme))
      Text($r('app.string.world_ai_generating'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ top: 16 })
      Text('分析角色设定并构建世界观, 可能需要 10–30 秒')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ top: 4 })

      if (this.generationError.length > 0) {
        Text(this.generationError)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.world_error'))
          .margin({ top: 16 })
        Button($r('app.string.world_ai_back_select'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .margin({ top: 12 })
          .padding({ left: 24, right: 24 })
          .onClick(() => {
            this.stage = WorldAICreateStage.InputTheme;
          })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder reviewView(): void {
    Column() {
      if (this.preview === null) {
        // 空占位
      } else {
        if (this.saveError.length > 0) {
          Text(this.saveError).fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.world_error')).width('100%')
            .textAlign(TextAlign.Center)
            .padding({ left: 16, right: 16, top: 4, bottom: 4 })
        }

        Scroll() {
          Column() {
            this.reviewWorldInfoCard()
            this.reviewLocationsCard()
            this.reviewLorebookCard()
            this.reviewCharNotesCard()

            Text($r('app.string.world_ai_player_name_label'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 4 })

            TextInput({ text: this.playerDisplayName, placeholder: $r('app.string.world_ai_player_name_placeholder') })
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .width('100%').height(44).padding({ left: 12, right: 12 })
              .margin({ left: 16, right: 16 })
              .onChange((v: string) => { this.playerDisplayName = v; })

            if (this.playerNameError.length > 0) {
              Text(this.playerNameError).fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.world_error')).width('100%')
                .padding({ left: 16, right: 16, top: 4 })
            }
          }
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Auto)

        Row() {
          Button($r('app.string.world_ai_regenerate'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(48).layoutWeight(1).margin({ right: 8 })
            .enabled(!this.isSaving && !this.isGenerating)
            .onClick(() => { if (this.vm !== null) { this.vm.generateWorld().then((): void => { this.syncFromVM(); }); } })

          Button($r('app.string.world_ai_confirm_create'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(48).layoutWeight(1)
            .enabled(!this.isSaving)
            .onClick(() => {
              if (this.vm !== null) {
                this.vm.playerDisplayName = this.playerDisplayName;
                this.vm.saveWorld().then((): void => { this.syncFromVM(); });
              }
            })
        }
        .width('100%').padding({ left: 16, right: 16, bottom: 16 })
      }
    }
    .width('100%').layoutWeight(1)
  }

  @Builder reviewWorldInfoCard(): void {
    if (this.preview !== null) {
      Column() {
        Text($r('app.string.world_ai_world_info'))
          .fontSize($r('app.float.app_font_body')).fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 4 })
        Column() {
          Text(this.preview.worldName).fontSize($r('app.float.app_font_title'))
            .fontWeight(FontWeight.Bold).fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          Text(this.preview.worldDescription).fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme)).margin({ top: 4 })
        }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
      }
      .width('100%').margin({ left: 12, right: 12, top: 8 })
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
    }
  }

  @Builder reviewLocationsCard(): void {
    if (this.preview !== null) {
      Column() {
        Text($r('app.string.world_ai_locations') + ' (' + this.preview.locations.length.toString() + ')')
          .fontSize($r('app.float.app_font_body')).fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 4 })
        Column() {
          ForEach(this.preview.locations, (loc: import('../../viewmodels/world/WorldAICreateViewModel').AiGeneratedLocation, idx: number) => {
            Column() {
              Text((idx + 1).toString() + '. ' + loc.name).fontWeight(FontWeight.Medium)
                .fontSize($r('app.float.app_font_body')).fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              Text(loc.description).fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme)).margin({ top: 2 })
            }.margin({ top: idx > 0 ? 8 : 0 })
          }, (loc: import('../../viewmodels/world/WorldAICreateViewModel').AiGeneratedLocation, idx: number): string => idx.toString())
        }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
      }
      .width('100%').margin({ left: 12, right: 12, top: 8 })
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
    }
  }

  @Builder reviewLorebookCard(): void {
    if (this.preview !== null) {
      Column() {
        Text($r('app.string.world_ai_lorebook') + ' (' + this.preview.lorebookEntries.length.toString() + ')')
          .fontSize($r('app.float.app_font_body')).fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 4 })
        Column() {
          ForEach(this.preview.lorebookEntries, (entry: import('../../viewmodels/world/WorldAICreateViewModel').AiGeneratedLorebookEntry, idx: number) => {
            Column() {
              Text((idx + 1).toString() + '. ' + entry.name).fontWeight(FontWeight.Medium)
                .fontSize($r('app.float.app_font_body')).fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              Text(entry.content).fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme)).margin({ top: 2 })
            }.margin({ top: idx > 0 ? 8 : 0 })
          }, (entry: import('../../viewmodels/world/WorldAICreateViewModel').AiGeneratedLorebookEntry, idx: number): string => idx.toString())
        }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
      }
      .width('100%').margin({ left: 12, right: 12, top: 8 })
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
    }
  }

  @Builder reviewCharNotesCard(): void {
    if (this.preview !== null) {
      Column() {
        Text($r('app.string.world_ai_char_notes'))
          .fontSize($r('app.float.app_font_body')).fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 4 })
        Column() {
          ForEach(this.preview.characterNotes, (note: import('../../viewmodels/world/WorldAICreateViewModel').AiGeneratedCharacterNote, idx: number) => {
            Column() {
              Text((idx + 1).toString() + '. ' + note.worldRole).fontWeight(FontWeight.Medium)
                .fontSize($r('app.float.app_font_body')).fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              Text(note.adaptation).fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme)).margin({ top: 2 })
            }.margin({ top: idx > 0 ? 8 : 0 })
          }, (note: import('../../viewmodels/world/WorldAICreateViewModel').AiGeneratedCharacterNote, idx: number): string => idx.toString())
        }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
      }
      .width('100%').margin({ left: 12, right: 12, top: 8 })
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
    }
  }
}
