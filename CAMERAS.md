# PTP Webcam Supported Camera Features

The tables below list what features are supported with which camera models. Values in parenthesis, such as _(YES)_ indicate unconfirmed cases.

## Nikon

### Full-Frame / FX

| Camera        | max resolution | Exposure Preview       | Exposure Correction | Aperture Control | Needs Memory Card |
| ------------- | -------------- | ---------------------- | ------------------- | ---------------- | ----------------- |
| (D3) [#11](https://github.com/dognotdog/ptpwebcam/issues/11) | ~640x480~ | ? | ? | ?             | ?                 |
| D4            | 640x480        | YES (Photography Mode) | YES                 | YES              | (NO)              |
| D700          | 640x480        | (NO)                   | (YES)               | (YES)            | ?                 |
| D750          | 640x480        | YES (Photography Mode) | YES                 | YES              | ?                 |
| D800 / D800E  | 640x480        | YES (Photography Mode) | YES                 | YES              | NO                |
| D810 / D810A  | 640x480        | YES (Photography Mode) | YES                 | YES              | (NO)              |
| D850          | 1024x768       | YES (Photography Mode) | YES                 | YES              | (NO)              |
| Z6            | 1024x768       | (YES)                  | ?                   | ?                | (NO)              |
| Z7            | 1024x768       | (YES)                  | ?                   | ?                | (NO)              |

#### Notes

- D800: LiveView timeout can be set to infinity via `CUSTOM SETTINGS MENU -> c Timers/AE Lock -> c4 Monitor off delay -> Live view`

### APS-C / DX

| Camera        | max resolution | Exposure Preview       | Exposure Correction | Aperture Control              | Needs Memory Card |
| ------------- | -------------- | ---------------------- | ------------------- | ----------------------------- | ----------------- |
| ~D40~         | no LiveView    | -                      | -                   | -                             | -                 |
| ~D60~         | no LiveView    | -                      | -                   | -                             | -                 |
| ~D80~         | no LiveView    | -                      | -                   | -                             | -                 |
| (D90) [#13](https://github.com/dognotdog/ptpwebcam/issues/13) | ~640x480~ | ? | ? | ?                         | ?                 |
| ~D200~        | no LiveView    | -                      | -                   | -                             | -                 |
| ~D3000~       | no LiveView    | -                      | -                   | -                             | -                 |
| D3400         | 640x480        | NO                     | YES                 | YES (fixed during LiveView)   | YES               |
| D3500         | (640x480)      | (NO)                   | (YES)               | (YES) (fixed during LiveView) | (YES)             |
| D5100         | 640x480        | NO                     | (YES)               | ?                             | (NO)              |
| D5500         | 640x480        | NO                     | (YES)               | ?                             | (NO)              |
| D5600         | 640x480        | NO                     | YES                 | ?                             | (NO)              |
| D7000         | 640x480        | NO                     | (YES)               | (YES)                         | ?                 |
| D7100         | 640x480        | NO                     | (YES)               | (YES)                         | ?                 |
| D7200         | 640x480        | NO                     | (YES)               | (YES)                         | ?                 |
| D7500         | 1024x768       | YES (Photography Mode) | (YES)               | (YES)                         | ?                 |
| Z50           | 1024x768       | (YES)                  | ?                   | ?                             | (NO)              |

#### Notes

- D5100, D5200: frequent shutter cycling [#4](https://github.com/dognotdog/ptpwebcam/issues/4)

