//
//  AVTPlayerViewController.h
//  AVToolkitExample
//
//  Created by Nicolai Persson on 26/03/14.
//  Copyright (c) 2014 Danish Broadcasting Corporation. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface AVTPlayerViewController : UIViewController
@property(nonatomic, strong) IBOutlet UIButton *toggleButton;
@property(nonatomic, strong) IBOutlet UILabel *statusLabel;
@property(nonatomic, strong) IBOutlet UITextView *textView;
@property(nonatomic, strong) IBOutlet UITextField *textField;
@property(nonatomic, strong) IBOutlet UISlider *positionSlider;
@property(nonatomic, strong) IBOutlet UISegmentedControl *segmentedControl;
@property (weak, nonatomic) IBOutlet UIBarButtonItem *subtitleBarButton;
@end
